import AVFoundation
import AppKit
import CoreMedia
import Foundation
import LivePhotoForgeCore
import SwiftUI

/// 拖入 → 选片段 → 自动选封面 → 一键生成。
@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case empty, inspecting, ready, converting, finished, failed
    }

    /// 起止两个输入框。回写时要跳过正在编辑的那个，否则用户打到一半就被改掉。
    enum InputField { case start, end }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var info: VideoInfo?
    @Published private(set) var stage: LivePhotoStage?
    @Published private(set) var stageProgress: Double = 0
    @Published private(set) var result: ConversionResult?
    @Published private(set) var failure: LivePhotoError?
    @Published var isTargeted = false

    // MARK: 裁剪

    @Published private(set) var selectionStart: Double = 0
    @Published private(set) var selectionDuration: Double = 3

    /// 关键帧时间点，时间轴上画竖线用，也是吸附和上/下一帧按钮的依据。
    @Published private(set) var keyframes: [Double] = []
    @Published private(set) var thumbnails: [NSImage] = []

    @Published var startInput: String = "0:00.00"
    @Published var endInput: String = "0:03.00"
    /// 输入值与实际落点不一致时的说明。关键帧间隔 2 秒时，
    /// 输 11.0 和 11.5 会落到同一个 10.0——不说明用户会以为输入被吞了。
    @Published private(set) var rangeHint: String?
    @Published private(set) var inputError: String?

    /// 开启后不再吸附，退回重编码路径，画质有损。
    @Published var preciseTrim = false {
        didSet {
            if !preciseTrim { setStart(selectionStart) } else { syncFields() }
            refreshRangeHint()
            scheduleCoverPreview()
        }
    }

    // MARK: 封面预览

    @Published private(set) var coverPreview: NSImage?
    @Published private(set) var coverTime: Double?
    @Published private(set) var isPickingCover = false

    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let durationPresets: [Double] = [1.5, 3, 5, 10]

    /// 拖拽起始快照。不驱动重绘，所以不加 @Published。
    /// （@State 在 macOS 27 SDK 里是宏，其插件只随完整 Xcode 分发。）
    var dragOriginStart: Double?
    var dragOriginDuration: Double?

    /// 回写输入框时留下的回声标记，用来区分「我自己写的」和「用户敲的」。
    private var echoStart: String?
    private var echoEnd: String?

    private var asset: AVURLAsset?
    private var coverTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?

    var maxDuration: Double { info.map { $0.durationSeconds } ?? 0 }
    var selectionEnd: Double { min(selectionStart + selectionDuration, maxDuration) }

    /// 超过 10 秒时提示：部分平台只认 3 秒以内。
    var showsLengthWarning: Bool { selectionDuration > 10 }

    /// 4K 存本地没问题，分享会被对方服务器二次压缩。
    var showsSharingCaveat: Bool {
        guard let info else { return false }
        return max(info.naturalSize.width, info.naturalSize.height) > 2160
    }

    // MARK: - 导入

    func accept(urls: [URL]) {
        guard let url = urls.first(where: {
            Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }) else {
            failure = LivePhotoError(.inspect, "只支持 MP4 / MOV / M4V 格式")
            phase = .failed
            return
        }
        load(url)
    }

    func load(_ url: URL) {
        coverTask?.cancel()
        timelineTask?.cancel()
        phase = .inspecting
        info = nil
        result = nil
        failure = nil
        keyframes = []
        thumbnails = []
        coverPreview = nil
        coverTime = nil
        rangeHint = nil
        inputError = nil

        Task {
            do {
                let inspected = try await VideoInspector.inspect(url: url)
                let loaded = AVURLAsset(
                    url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                )
                self.asset = loaded
                self.info = inspected
                self.selectionDuration = min(3, inspected.durationSeconds)
                self.selectionStart = 0
                self.syncFields()
                self.phase = .ready
                self.loadTimeline(for: loaded, duration: inspected.duration)
                self.scheduleCoverPreview()
            } catch let error as LivePhotoError {
                self.failure = error
                self.phase = .failed
            } catch {
                self.failure = LivePhotoError(.inspect, "解析失败", underlying: error)
                self.phase = .failed
            }
        }
    }

    func reset() {
        coverTask?.cancel()
        timelineTask?.cancel()
        phase = .empty
        info = nil
        asset = nil
        result = nil
        failure = nil
        stage = nil
        stageProgress = 0
        keyframes = []
        thumbnails = []
        coverPreview = nil
        coverTime = nil
        rangeHint = nil
        inputError = nil
    }

    // MARK: - 时间轴素材

    private func loadTimeline(for asset: AVURLAsset, duration: CMTime) {
        timelineTask = Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let times = try? await KeyframeIndex.keyframeTimes(
                   track: track, in: CMTimeRange(start: .zero, duration: duration)
               ) {
                if Task.isCancelled { return }
                self.keyframes = times.map(\.seconds)
                self.setStart(self.selectionStart)
            }

            // 缩略图条只求快，容差不设 .zero。
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            let count = 24
            var times: [CMTime] = []
            for index in 0..<count {
                let ratio = (Double(index) + 0.5) / Double(count)
                times.append(CMTimeMultiplyByFloat64(duration, multiplier: ratio))
            }
            var images: [NSImage] = []
            for await result in generator.images(for: times) {
                if Task.isCancelled { return }
                if case .success(let value) = result {
                    images.append(NSImage(
                        cgImage: value.image,
                        size: CGSize(width: value.image.width, height: value.image.height)
                    ))
                }
            }
            if Task.isCancelled { return }
            self.thumbnails = images
        }
    }

    // MARK: - 选区编辑

    /// 起点吸附到最近的前一个关键帧。
    func snap(_ seconds: Double) -> Double {
        guard !preciseTrim, !keyframes.isEmpty else { return seconds }
        return keyframes.last(where: { $0 <= seconds + 0.0005 }) ?? 0
    }

    var startCeiling: Double { max(0, maxDuration - selectionDuration) }

    func setStart(_ seconds: Double, commit: Bool = false, skipSync: InputField? = nil) {
        selectionStart = snap(min(max(0, seconds), startCeiling))
        syncFields(skip: skipSync)
        if commit { scheduleCoverPreview() }
    }

    func setDuration(_ seconds: Double, commit: Bool = false) {
        let upper = max(0.2, maxDuration - selectionStart)
        selectionDuration = min(max(0.2, seconds), upper)
        syncFields()
        if commit { scheduleCoverPreview() }
    }

    /// 点预设只是把时长设过去，按钮随之高亮；把手照样能拖。
    func applyPreset(_ seconds: Double) {
        setDuration(seconds)
        // 时长变长可能把选区顶出视频尾部，起点跟着回退。
        setStart(selectionStart, commit: true)
        refreshRangeHint()
    }

    func isPresetActive(_ preset: Double) -> Bool {
        abs(selectionDuration - preset) < 0.01
    }

    var availablePresets: [Double] {
        Self.durationPresets.filter { $0 <= maxDuration + 0.001 }
    }

    // MARK: - 关键帧步进

    /// 吸附模式下，起点只能落在关键帧上，所以给两个按钮直接跳到相邻关键帧，
    /// 免得用户靠拖拽去猜。
    var canStepKeyframes: Bool { !preciseTrim && keyframes.count > 1 }

    var previousKeyframe: Double? {
        keyframes.last(where: { $0 < selectionStart - 0.005 })
    }

    var nextKeyframe: Double? {
        keyframes.first(where: { $0 > selectionStart + 0.005 && $0 <= startCeiling + 0.005 })
    }

    func stepToPreviousKeyframe() {
        guard let target = previousKeyframe else { return }
        setStart(target, commit: true)
        refreshRangeHint()
    }

    func stepToNextKeyframe() {
        guard let target = nextKeyframe else { return }
        setStart(target, commit: true)
        refreshRangeHint()
    }

    // MARK: - 起止输入框

    /// 边输边生效。改起点，终点跟着走（终点 = 起点 + 时长）。
    func previewStartInput() {
        if startInput == echoStart { echoStart = nil; return }
        echoStart = nil
        guard info != nil else { return }
        guard let requested = Timecode.parse(startInput) else {
            inputError = "读不懂这个时间。支持 12.5、1:02.5、01:02:03 几种写法。"
            return
        }
        inputError = nil
        setStart(min(max(0, requested), startCeiling), commit: true, skipSync: .start)
        refreshRangeHint(typedStart: requested)
    }

    /// 改终点，起点跟着走（起点 = 终点 − 时长），时长不变。
    func previewEndInput() {
        if endInput == echoEnd { echoEnd = nil; return }
        echoEnd = nil
        guard info != nil else { return }
        guard let requested = Timecode.parse(endInput) else {
            inputError = "读不懂这个时间。支持 12.5、1:02.5、01:02:03 几种写法。"
            return
        }
        inputError = nil
        let clamped = min(max(selectionDuration, requested), maxDuration)
        setStart(clamped - selectionDuration, commit: true, skipSync: .end)
        refreshRangeHint(typedEnd: requested)
    }

    private func syncFields(skip: InputField? = nil) {
        if skip != .start {
            let text = Timecode.format(selectionStart)
            if text != startInput { echoStart = text; startInput = text }
        }
        if skip != .end {
            let text = Timecode.format(selectionEnd)
            if text != endInput { echoEnd = text; endInput = text }
        }
    }

    /// 输入值和实际落点对不上时说清楚为什么。
    private func refreshRangeHint(typedStart: Double? = nil, typedEnd: Double? = nil) {
        var reasons: [String] = []

        if let typedStart {
            if typedStart > startCeiling + 0.005 {
                reasons.append(String(format: "视频只到 %@，%.2f s 的片段最晚从 %@ 开始",
                                      Timecode.format(maxDuration), selectionDuration,
                                      Timecode.format(startCeiling)))
            } else if abs(typedStart - selectionStart) > 0.005 {
                reasons.append("起点吸附到了关键帧")
            }
        }
        if let typedEnd {
            if typedEnd > maxDuration + 0.005 {
                reasons.append(String(format: "视频只到 %@", Timecode.format(maxDuration)))
            } else if typedEnd < selectionDuration - 0.005 {
                reasons.append(String(format: "终点不能早于 %.2f s（当前时长）", selectionDuration))
            } else if abs(typedEnd - selectionEnd) > 0.005 {
                reasons.append("起点吸附到了关键帧，终点跟着前移")
            }
        }

        guard !reasons.isEmpty else { rangeHint = nil; return }
        rangeHint = String(format: "实际 %@ – %@ · %@",
                           Timecode.format(selectionStart),
                           Timecode.format(selectionEnd),
                           reasons.joined(separator: "，"))
    }

    // MARK: - 封面预览

    /// 选区变化后重挑封面。拖动过程中不跑，停下 250ms 才跑。
    func scheduleCoverPreview() {
        guard let asset, phase != .converting else { return }
        coverTask?.cancel()
        let range = CMTimeRange(
            start: CMTime(seconds: selectionStart, preferredTimescale: 600),
            duration: CMTime(seconds: selectionDuration, preferredTimescale: 600)
        )
        isPickingCover = true
        coverTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard let picked = try? await CoverFrameExtractor.pickSharpestFrame(
                from: asset, in: range, sampleCount: 16
            ) else {
                self.isPickingCover = false
                return
            }
            if Task.isCancelled { return }
            let image = picked.frame.image
            self.coverPreview = NSImage(
                cgImage: image, size: CGSize(width: image.width, height: image.height)
            )
            self.coverTime = picked.frame.actualTime.seconds
            self.isPickingCover = false
        }
    }

    // MARK: - 生成

    func convert() {
        guard let info else { return }
        phase = .converting
        stage = .inspect
        stageProgress = 0
        failure = nil

        let request = ConversionRequest(
            sourceURL: info.url,
            start: CMTime(seconds: selectionStart, preferredTimescale: 600),
            duration: CMTime(seconds: selectionDuration, preferredTimescale: 600),
            cover: .automatic(sampleCount: 24),
            coverFormat: .heic,
            coverQuality: 1.0,
            keepAudio: true,
            preciseTrim: preciseTrim,
            importToLibrary: true
        )

        Task {
            do {
                let produced = try await LivePhotoForge.convert(request) { stage, fraction in
                    Task { @MainActor in
                        self.stage = stage
                        self.stageProgress = fraction
                    }
                }
                self.result = produced
                self.phase = .finished
            } catch let error as LivePhotoError {
                self.failure = error
                self.phase = .failed
            } catch {
                self.failure = LivePhotoError(.remux, "生成失败", underlying: error)
                self.phase = .failed
            }
        }
    }

    func revealInPhotos() {
        guard let identifier = result?.importResult?.localIdentifier else { return }
        PhotoLibraryImporter.revealInPhotos(localIdentifier: identifier)
    }

    /// 按源码率粗估成品体积。
    var estimatedSize: Int64? {
        guard let info else { return nil }
        return Int64(Double(info.videoBitrate) * selectionDuration / 8) + 1_200_000
    }

    static func timecode(_ seconds: Double) -> String { Timecode.format(seconds) }
}
