import AVFoundation
import CoreMedia
import Foundation

public struct RemuxResult: Sendable {
    public let outputURL: URL
    /// 实际生效的起点。passthrough 下它是「吸附后」的关键帧时间，可能早于用户要求的起点。
    public let actualStart: CMTime
    public let actualEnd: CMTime
    public let didPassthrough: Bool
    public let outputSize: Int64
    public let wroteAudio: Bool
}

public struct RemuxRequest: Sendable {
    public var sourceURL: URL
    public var outputURL: URL
    public var timeRange: CMTimeRange
    public var identity: AssetIdentity
    /// 封面帧在源时间轴上的位置，用来写 still-image-time 定时元数据轨。
    public var stillImageTime: CMTime
    public var keepAudio: Bool
    /// 开启后走重编码路径，裁剪点不再吸附到关键帧（方案 4.2「精确裁剪」）。
    public var preciseTrim: Bool

    public init(
        sourceURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange,
        identity: AssetIdentity,
        stillImageTime: CMTime,
        keepAudio: Bool = true,
        preciseTrim: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.timeRange = timeRange
        self.identity = identity
        self.stillImageTime = stillImageTime
        self.keepAudio = keepAudio
        self.preciseTrim = preciseTrim
    }
}

/// 用 AVAssetReader + AVAssetWriter 把源视频重封装成带 Live Photo 元数据的 MOV。
///
/// 关键约定（方案 5.2）：两端 `outputSettings` 均为 nil 时走 passthrough，
/// 样本原样搬运，不解码不重编码。绝不使用 AVAssetExportSession——它不给写
/// 自定义定时元数据轨的口子。
public enum LivePhotoVideoWriter {

    public static func remux(
        _ request: RemuxRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> RemuxResult {
        let asset = AVURLAsset(
            url: request.sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivePhotoError(.remux, "文件里没有视频轨")
        }
        let audioTrack = request.keepAudio
            ? try await asset.loadTracks(withMediaType: .audio).first
            : nil

        let passthrough = !request.preciseTrim
        let start: CMTime
        var end = request.timeRange.end
        if passthrough {
            start = try await KeyframeIndex.snapToPrecedingKeyframe(
                track: videoTrack, time: request.timeRange.start
            )
            // 吸附让起点前移时，终点跟着前移，时长保持用户选定的值。
            // 否则选 5 秒会得到 6.2 秒，「5 秒实况」就不成立了。
            let shift = request.timeRange.start - start
            if shift > .zero {
                let assetDuration = try await asset.load(.duration)
                end = min(end - shift, assetDuration)
            }
        } else {
            start = request.timeRange.start
        }
        guard end > start else {
            throw LivePhotoError(.remux, "裁剪区间无效：起点 \(start.seconds)s 不早于终点 \(end.seconds)s")
        }
        let readRange = CMTimeRange(start: start, end: end)

        try? FileManager.default.removeItem(at: request.outputURL)
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // ---- Reader ----
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw LivePhotoError(.remux, "无法创建 AVAssetReader", underlying: error) }
        reader.timeRange = readRange

        // outputSettings 传 nil —— passthrough 的一半。
        let videoOutputSettings: [String: Any]? = passthrough ? nil : [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw LivePhotoError(.remux, "AVAssetReader 拒绝视频输出（编码可能不支持 passthrough）")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let settings: [String: Any]? = passthrough ? nil : [
                AVFormatIDKey: kAudioFormatLinearPCM
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // ---- Writer ----
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mov) }
        catch { throw LivePhotoError(.remux, "无法创建 AVAssetWriter", underlying: error) }

        // 配对要素之二：MOV 级别的 content identifier。
        writer.metadata = [contentIdentifierItem(request.identity)]

        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let videoInput: AVAssetWriterInput
        if passthrough {
            videoInput = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat
            )
        } else {
            videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: try await reencodeVideoSettings(for: videoTrack)
            )
        }
        videoInput.expectsMediaDataInRealTime = false
        // 旋转信息不能丢，否则竖屏素材转出来是横的。
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else {
            throw LivePhotoError(.remux, "AVAssetWriter 拒绝视频输入")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioTrack, audioOutput != nil {
            let format = try await audioTrack.load(.formatDescriptions).first
            let input: AVAssetWriterInput
            if passthrough {
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            } else {
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: 2,
                    AVSampleRateKey: 44_100,
                    AVEncoderBitRateKey: 128_000,
                ])
            }
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        // 配对要素之三：still-image-time 定时元数据轨。缺了它，长按播放的静止画面位置会错。
        let metadataInput = makeStillImageTimeInput()
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else {
            throw LivePhotoError(.remux, "AVAssetWriter 拒绝 still-image-time 元数据轨")
        }
        writer.add(metadataInput)

        // ---- 跑起来 ----
        guard writer.startWriting() else {
            throw LivePhotoError(.remux, "AVAssetWriter 启动失败", underlying: writer.error)
        }
        writer.startSession(atSourceTime: start)

        let stillTime = clamp(request.stillImageTime, to: readRange)
        let frameDuration = CMTime(value: 1, timescale: 30)
        let stillRange = CMTimeRange(
            start: stillTime,
            duration: min(frameDuration, max(end - stillTime, CMTime(value: 1, timescale: 600)))
        )
        let group = AVTimedMetadataGroup(items: [stillImageTimeItem()], timeRange: stillRange)
        do { try metadataAdaptor.append(group) }
        catch { throw LivePhotoError(.remux, "写入 still-image-time 元数据失败", underlying: error) }
        metadataInput.markAsFinished()

        guard reader.startReading() else {
            throw LivePhotoError(.remux, "AVAssetReader 启动失败", underlying: reader.error)
        }

        var pumps: [(AVAssetWriterInput, AVAssetReaderTrackOutput, String)] = [
            (videoInput, videoOutput, "video")
        ]
        if let audioInput, let audioOutput { pumps.append((audioInput, audioOutput, "audio")) }

        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for (input, output, label) in pumps {
                taskGroup.addTask {
                    try await pump(
                        input: input, output: output, label: label,
                        range: readRange, progress: label == "video" ? progress : nil
                    )
                }
            }
            try await taskGroup.waitForAll()
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw LivePhotoError(.remux, "读取样本中断", underlying: reader.error)
        }
        reader.cancelReading()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LivePhotoError(.remux, "封装未完成（status=\(writer.status.rawValue)）", underlying: writer.error)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: request.outputURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return RemuxResult(
            outputURL: request.outputURL,
            actualStart: start,
            actualEnd: end,
            didPassthrough: passthrough,
            outputSize: size,
            wroteAudio: audioInput != nil
        )
    }

    // MARK: - 样本搬运

    private static func pump(
        input: AVAssetWriterInput,
        output: AVAssetReaderTrackOutput,
        label: String,
        range: CMTimeRange,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let queue = DispatchQueue(label: "com.livephotoforge.pump.\(label)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finished = Finished()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if finished.trySet() { continuation.resume() }
                        return
                    }
                    if let progress, range.duration.seconds > 0 {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let done = (pts - range.start).seconds / range.duration.seconds
                        progress(max(0, min(1, done)))
                    }
                    if !input.append(sample) {
                        input.markAsFinished()
                        if finished.trySet() {
                            continuation.resume(throwing: LivePhotoError(
                                .remux, "追加 \(label) 样本失败，写入器已进入错误状态"
                            ))
                        }
                        return
                    }
                }
            }
        }
    }

    /// continuation 只能 resume 一次，用它兜住回调重入。
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func trySet() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - 元数据

    static func contentIdentifierItem(_ identity: AssetIdentity) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: QuickTimeMetadata.contentIdentifierID)
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = identity.value as NSString
        return item
    }

    static func stillImageTimeItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = AVMetadataIdentifier(rawValue: QuickTimeMetadata.stillImageTimeID)
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        item.value = 0 as NSNumber
        return item
    }

    private static func makeStillImageTimeInput() -> AVAssetWriterInput {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                QuickTimeMetadata.stillImageTimeID,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String,
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &description
        )
        let input = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: description
        )
        input.expectsMediaDataInRealTime = false
        return input
    }

    // MARK: - 重编码路径（精确裁剪时才走）

    private static func reencodeVideoSettings(for track: AVAssetTrack) async throws -> [String: Any] {
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.estimatedDataRate)
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(abs(size.width)),
            AVVideoHeightKey: Int(abs(size.height)),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(max(rate, 8_000_000)),
            ],
        ]
    }

    private static func clamp(_ time: CMTime, to range: CMTimeRange) -> CMTime {
        if time < range.start { return range.start }
        if time > range.end { return range.end }
        return time
    }
}
