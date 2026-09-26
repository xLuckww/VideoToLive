import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public struct RemuxResult: Sendable {
    public let outputURL: URL
    /// 实际生效的起点。passthrough 下它是「吸附后」的关键帧时间，可能早于用户要求的起点。
    public let actualStart: CMTime
    public let actualEnd: CMTime
    public let didPassthrough: Bool
    /// 原生竖屏素材被转成了横屏存储加旋转标记（这种情况下必然重编码）。
    public let rotatedToLandscape: Bool
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
///
/// 例外：原生竖屏存储的素材在 iPhone 上播放实况会发糊，必须转成横屏存储加
/// 旋转标记，这只能重编码，见 `VideoInspector.needsLandscapeStorage`。
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

        let (codedSize, sourceTransform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let rotateToLandscape = VideoInspector.needsLandscapeStorage(
            codedSize: codedSize, transform: sourceTransform
        )
        // 吸附只跟「精确裁剪」挂钩，必须和 LivePhotoConverter 里算区间的条件一致。
        // 竖屏重编码仍然吸附：区间由编排层统一算好，这里不能另起一套。
        let snapToKeyframe = !request.preciseTrim
        let passthrough = snapToKeyframe && !rotateToLandscape
        let audioPassthrough = snapToKeyframe
        let start: CMTime
        var end = request.timeRange.end
        if snapToKeyframe {
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
        let plan: ReencodePlan? = passthrough
            ? nil : try await reencodePlan(for: videoTrack, rotate: rotateToLandscape)
        let videoOutputSettings: [String: Any]? = plan.map {
            [kCVPixelBufferPixelFormatTypeKey as String: $0.pixelFormat]
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw LivePhotoError(.remux, "AVAssetReader 拒绝视频输出（编码可能不支持 passthrough）")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let settings: [String: Any]? = audioPassthrough ? nil : [
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
        var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if let plan {
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: plan.outputSettings)
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: plan.pixelFormat,
                    kCVPixelBufferWidthKey as String: plan.width,
                    kCVPixelBufferHeightKey as String: plan.height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ]
            )
        } else {
            videoInput = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat
            )
        }
        videoInput.expectsMediaDataInRealTime = false
        // 旋转信息不能丢，否则竖屏素材转出来是横的。
        videoInput.transform = rotateToLandscape
            ? landscapeStorageTransform(storedSize: CGSize(width: plan!.width, height: plan!.height),
                                        source: sourceTransform)
            : sourceTransform
        guard writer.canAdd(videoInput) else {
            throw LivePhotoError(.remux, "AVAssetWriter 拒绝视频输入")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioTrack, audioOutput != nil {
            let format = try await audioTrack.load(.formatDescriptions).first
            let input: AVAssetWriterInput
            if audioPassthrough {
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
        // append 不抛错，而是用返回值表示成败。忽略返回值会静默产出一个缺少
        // still-image-time 的文件：照片 App 可能仍认成实况，但静止画面位置不对。
        guard metadataAdaptor.append(group) else {
            throw LivePhotoError(.remux, "写入 still-image-time 元数据失败", underlying: writer.error)
        }
        metadataInput.markAsFinished()

        guard reader.startReading() else {
            throw LivePhotoError(.remux, "AVAssetReader 启动失败", underlying: reader.error)
        }

        let rotator = rotateToLandscape ? try makeRotator() : nil
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            taskGroup.addTask {
                if let pixelAdaptor {
                    try await pumpFrames(
                        adaptor: pixelAdaptor, output: videoOutput, rotator: rotator,
                        range: readRange, progress: progress
                    )
                } else {
                    try await pump(
                        input: videoInput, output: videoOutput, label: "video",
                        range: readRange, progress: progress
                    )
                }
            }
            if let audioInput, let audioOutput {
                taskGroup.addTask {
                    try await pump(
                        input: audioInput, output: audioOutput, label: "audio",
                        range: readRange, progress: nil
                    )
                }
            }
            try await taskGroup.waitForAll()
        }
        if let rotator { VTPixelRotationSessionInvalidate(rotator) }

        if reader.status == .failed {
            writer.cancelWriting()
            throw LivePhotoError(.remux, "读取样本中断", underlying: reader.error)
        }
        reader.cancelReading()

        // 逐帧追加的像素没有时长，不收尾的话最后一帧会被截掉，成品比区间短一帧。
        if !passthrough { writer.endSession(atSourceTime: end) }
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
            rotatedToLandscape: rotateToLandscape,
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
        let queue = DispatchQueue(label: "com.xluckww.videotolive.pump.\(label)")
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

    /// 重编码路径：解码后的帧按需旋转，再交给编码器。
    private static func pumpFrames(
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        output: AVAssetReaderTrackOutput,
        rotator: VTPixelRotationSession?,
        range: CMTimeRange,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let input = adaptor.assetWriterInput
        let queue = DispatchQueue(label: "com.xluckww.videotolive.pump.frames")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let finished = Finished()
            func fail(_ message: String) {
                input.markAsFinished()
                if finished.trySet() {
                    continuation.resume(throwing: LivePhotoError(.remux, message))
                }
            }
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        if finished.trySet() { continuation.resume() }
                        return
                    }
                    // 解码器偶尔会吐出不带图像的样本（比如只携带标记），跳过即可。
                    guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)

                    var frame = source
                    if let rotator {
                        guard let pool = adaptor.pixelBufferPool else {
                            return fail("编码器没有提供像素缓冲池")
                        }
                        var rotated: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rotated)
                        guard let rotated,
                              VTPixelRotationSessionRotateImage(rotator, source, rotated) == noErr
                        else { return fail("旋转视频帧失败") }
                        // 色彩空间等附加信息跟着帧走，丢了会偏色。
                        CVBufferPropagateAttachments(source, rotated)
                        frame = rotated
                    }

                    if let progress, range.duration.seconds > 0 {
                        let done = (pts - range.start).seconds / range.duration.seconds
                        progress(max(0, min(1, done)))
                    }
                    if !adaptor.append(frame, withPresentationTime: pts) {
                        return fail("追加视频帧失败，写入器已进入错误状态")
                    }
                }
            }
        }
    }

    /// 顺时针转 90°：竖屏画面存成横屏，显示时再由旋转标记转回来。
    private static func makeRotator() throws -> VTPixelRotationSession {
        var session: VTPixelRotationSession?
        guard VTPixelRotationSessionCreate(nil, &session) == noErr,
              let session else {
            throw LivePhotoError(.remux, "无法创建视频帧旋转会话")
        }
        VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_Rotation, value: kVTRotation_CW90)
        return session
    }

    /// 横屏存储的帧要逆时针转 90° 才是原来的竖屏画面，再叠加源文件原有的变换
    /// （比如倒置拍摄的 180°）。平移量按变换后的包围盒归零，让画面落在正象限。
    static func landscapeStorageTransform(storedSize: CGSize, source: CGAffineTransform) -> CGAffineTransform {
        let back = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: storedSize.width)
        var transform = back.concatenating(source)
        let box = CGRect(origin: .zero, size: storedSize).applying(transform)
        transform.tx -= box.minX
        transform.ty -= box.minY
        return transform
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

    // MARK: - 重编码路径（精确裁剪或原生竖屏素材才走）

    private struct ReencodePlan {
        let pixelFormat: OSType
        let width: Int
        let height: Int
        let outputSettings: [String: Any]
    }

    /// 尽量贴着源走：10-bit 源用 10-bit 解码和 Main 10 编码，码率不低于源，
    /// 色彩标记照抄。竖屏转横屏存储时宽高互换。
    private static func reencodePlan(for track: AVAssetTrack, rotate: Bool) async throws -> ReencodePlan {
        let (size, rate, fps, descriptions) = try await track.load(
            .naturalSize, .estimatedDataRate, .nominalFrameRate, .formatDescriptions
        )
        let description = descriptions.first
        let bits = description.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent)
        } as? NSNumber
        let tenBit = (bits?.intValue ?? 8) > 8

        let codedWidth = Int(abs(size.width)), codedHeight = Int(abs(size.height))
        let (width, height) = rotate ? (codedHeight, codedWidth) : (codedWidth, codedHeight)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(max(rate, 8_000_000)),
            AVVideoProfileLevelKey: tenBit
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        if fps > 0 {
            compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded())
            compression[AVVideoMaxKeyFrameIntervalKey] = Int(fps.rounded())
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let description,
           let primaries = CMFormatDescriptionGetExtension(
               description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
           let transfer = CMFormatDescriptionGetExtension(
               description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
           let matrix = CMFormatDescriptionGetExtension(
               description, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
        }

        return ReencodePlan(
            pixelFormat: tenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: width,
            height: height,
            outputSettings: settings
        )
    }

    private static func clamp(_ time: CMTime, to range: CMTimeRange) -> CMTime {
        if time < range.start { return range.start }
        if time > range.end { return range.end }
        return time
    }
}
