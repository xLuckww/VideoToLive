import AVFoundation
import CoreMedia
import Foundation

/// 封面帧的选取方式（方案 4.3）。
public enum CoverSelection: Sendable {
    case automatic(sampleCount: Int)
    case manual(time: CMTime)
}

public struct ConversionRequest: Sendable {
    public var sourceURL: URL
    public var start: CMTime
    public var duration: CMTime
    public var cover: CoverSelection
    public var coverFormat: CoverImageFormat
    public var coverQuality: Double
    public var keepAudio: Bool
    public var preciseTrim: Bool
    public var workDirectory: URL
    public var importToLibrary: Bool

    public init(
        sourceURL: URL,
        start: CMTime = .zero,
        duration: CMTime = CMTime(value: 3, timescale: 1),
        cover: CoverSelection = .automatic(sampleCount: 24),
        coverFormat: CoverImageFormat = .heic,
        coverQuality: Double = 1.0,
        keepAudio: Bool = true,
        preciseTrim: Bool = false,
        workDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoToLive", isDirectory: true),
        importToLibrary: Bool = true
    ) {
        self.sourceURL = sourceURL
        self.start = start
        self.duration = duration
        self.cover = cover
        self.coverFormat = coverFormat
        self.coverQuality = coverQuality
        self.keepAudio = keepAudio
        self.preciseTrim = preciseTrim
        self.workDirectory = workDirectory
        self.importToLibrary = importToLibrary
    }
}

public struct ConversionResult: Sendable {
    public let identity: AssetIdentity
    public let info: VideoInfo
    public let photoURL: URL
    public let videoURL: URL
    public let coverTime: CMTime
    public let coverSharpness: Double?
    public let remux: RemuxResult
    public let photoSize: Int64
    public let importResult: ImportResult?

    public var totalSize: Int64 { photoSize + remux.outputSize }
}

/// 阶段一的全链路编排：解析 → 抽帧 → 编码封面 → 封装 → 写入图库。
public enum LivePhotoConverter {

    public static func convert(
        _ request: ConversionRequest,
        onStage: (@Sendable (LivePhotoStage, Double) -> Void)? = nil
    ) async throws -> ConversionResult {

        onStage?(.inspect, 0)
        let info = try await VideoInspector.inspect(url: request.sourceURL)
        if request.preciseTrim == false, case .reencode(let reason) = info.mode {
            throw LivePhotoError(.inspect,
                "该文件无法无损直通：\(reason)。请开启「精确裁剪 / 重编码」后重试。")
        }
        let asset = AVURLAsset(
            url: request.sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let requestedEnd = min(request.start + request.duration, info.duration)
        guard requestedEnd > request.start else {
            throw LivePhotoError(.inspect, "裁剪区间超出视频时长")
        }

        // 吸附必须在这里算一次，而且只算这一次。
        // 封面挑选和视频封装都要用同一个区间——否则会出现「封面帧落在
        // 输出片段之外」这种自相矛盾的结果。
        var range = CMTimeRange(start: request.start, end: requestedEnd)
        if !request.preciseTrim,
           let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            let snapped = try await KeyframeIndex.snapToPrecedingKeyframe(
                track: videoTrack, time: request.start
            )
            let shift = request.start - snapped
            if shift > .zero {
                // 起点前移多少，终点跟着前移多少，保住用户选定的时长。
                range = CMTimeRange(start: snapped, end: min(requestedEnd - shift, info.duration))
            }
        }
        onStage?(.inspect, 1)

        let identity = AssetIdentity.generate()
        let stem = request.sourceURL.deletingPathExtension().lastPathComponent
        let directory = request.workDirectory.appendingPathComponent(identity.value, isDirectory: true)
        let photoURL = directory.appendingPathComponent("\(stem).\(request.coverFormat.fileExtension)")
        let videoURL = directory.appendingPathComponent("\(stem).mov")
        // 失败或取消时连同已经写好的封面一起清掉，不在临时目录里留半成品。
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: directory) } }

        // 抽帧
        onStage?(.extractCover, 0)
        let frame: CoverFrame
        var sharpness: Double?
        switch request.cover {
        case .automatic(let sampleCount):
            let picked = try await CoverFrameExtractor.pickSharpestFrame(
                from: asset, in: range, sampleCount: sampleCount
            )
            frame = picked.frame
            sharpness = picked.score
        case .manual(let time):
            frame = try await CoverFrameExtractor.extract(
                from: asset, at: clamp(time, to: range)
            )
        }
        onStage?(.extractCover, 1)
        // 队列里的取消要能在阶段之间生效，至少别在取消之后还往图库里写。
        try Task.checkCancellation()

        // 编码封面
        onStage?(.encodeCover, 0)
        try CoverFrameExtractor.writeStillImage(
            frame, identity: identity,
            format: request.coverFormat, quality: request.coverQuality, to: photoURL
        )
        guard let readback = CoverFrameExtractor.readAssetIdentifier(from: photoURL),
              readback == identity.value else {
            throw LivePhotoError(.encodeCover,
                "封面写入后回读不到 Maker Note 键 \"17\"，配对一定会失败")
        }
        let photoSize = ((try? FileManager.default.attributesOfItem(atPath: photoURL.path))?[.size]
            as? NSNumber)?.int64Value ?? 0
        onStage?(.encodeCover, 1)
        try Task.checkCancellation()

        // 封装
        onStage?(.remux, 0)
        let remux = try await LivePhotoVideoWriter.remux(
            RemuxRequest(
                sourceURL: request.sourceURL,
                outputURL: videoURL,
                timeRange: range,
                identity: identity,
                stillImageTime: frame.actualTime,
                keepAudio: request.keepAudio,
                preciseTrim: request.preciseTrim
            ),
            progress: { onStage?(.remux, $0) }
        )
        onStage?(.remux, 1)

        // 不变式：封面帧必须落在成品区间内。违反了说明吸附与挑帧算的不是同一个
        // 区间，成品会出现「长按播放停在一个根本不在片段里的画面」。
        guard frame.actualTime >= remux.actualStart, frame.actualTime <= remux.actualEnd else {
            throw LivePhotoError(.remux, String(
                format: "内部不一致：封面帧 %.3fs 落在成品区间 %.3f–%.3fs 之外",
                frame.actualTime.seconds, remux.actualStart.seconds, remux.actualEnd.seconds))
        }

        // 写入图库
        try Task.checkCancellation()
        var importResult: ImportResult?
        if request.importToLibrary {
            onStage?(.importLibrary, 0)
            importResult = try await PhotoLibraryImporter.importLivePhoto(
                photoURL: photoURL, videoURL: videoURL
            )
            onStage?(.importLibrary, 1)
        }

        finished = true
        return ConversionResult(
            identity: identity,
            info: info,
            photoURL: photoURL,
            videoURL: videoURL,
            coverTime: frame.actualTime,
            coverSharpness: sharpness,
            remux: remux,
            photoSize: photoSize,
            importResult: importResult
        )
    }

    private static func clamp(_ time: CMTime, to range: CMTimeRange) -> CMTime {
        if time < range.start { return range.start }
        if time > range.end { return range.end }
        return time
    }
}
