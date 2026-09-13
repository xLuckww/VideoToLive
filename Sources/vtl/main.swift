import AVFoundation
import CoreMedia
import Foundation
import VideoToLiveCore

// 阶段一的测试入口。没有外部依赖，手写参数解析。

let usage = """
vtl — VideoToLive 命令行工具

用法:
  vtl inspect <video>
      解析并打印时长 / 分辨率 / 帧率 / 编码 / 转换模式徽标

  vtl keyframes <video> [--start <秒>] [--duration <秒>]
      列出区间内的关键帧位置（裁剪吸附的依据）

  vtl convert <video> [选项]
      跑通全链路：抽帧 → 编码封面 → 封装 → 写入图库
      --cover <秒|auto>   封面帧时间点，auto 走清晰度自动挑选（默认 auto）
      --start <秒|时间码>  裁剪起点，默认 0，支持 12.5 / 1:02.5 两种写法
      --duration <秒>     裁剪时长，默认 3
      --out <目录>        产物输出目录，默认临时目录
      --format heic|jpeg  封面格式，默认 heic
      --quality <0-1>     封面质量，默认 1.0
      --no-audio          丢弃音轨
      --precise           精确裁剪（退回重编码，画质有损）
      --no-import         只产出文件，不写入照片图库

  vtl frames <video> --at <秒> [--count <n>]
      从指定时间点连续抽 n 帧，打印每帧的时间与像素指纹
      用来验证「方向键逐帧步进」确实不跳帧不重复（验收标准 5）

  vtl stress <video> [--times <n>] [--duration <秒>]
      在同一进程里连续转换 n 次，报告峰值内存（验收标准 6）

  vtl verify <mov> [<封面图>]
      回读 MOV 的 content.identifier / still-image-time 轨，以及封面的 Maker Note
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                let next = index + 1 < raw.count ? raw[index + 1] : nil
                if let next, !next.hasPrefix("--") {
                    flags[key] = next
                    index += 2
                } else {
                    flags[key] = "true"
                    index += 1
                }
            } else {
                positional.append(token)
                index += 1
            }
        }
    }

    /// 同时接受纯秒数和 1:02.5 这样的时间码。
    func double(_ key: String) -> Double? { flags[key].flatMap(Timecode.parse) }
    func bool(_ key: String) -> Bool { flags[key] == "true" }
}

func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func megabytes(_ bytes: Int64) -> String {
    String(format: "%.2f MB", Double(bytes) / 1_048_576)
}

// MARK: - 子命令

func runInspect(_ args: Args) async throws {
    guard let path = args.positional.first else { fail("缺少视频路径\n\n" + usage) }
    let info = try await VideoInspector.inspect(url: url(path))
    print(info.summary)
}

func runKeyframes(_ args: Args) async throws {
    guard let path = args.positional.first else { fail("缺少视频路径\n\n" + usage) }
    let asset = AVURLAsset(url: url(path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        fail("文件里没有视频轨")
    }
    let start = time(args.double("start") ?? 0)
    let duration: CMTime
    if let seconds = args.double("duration") {
        duration = time(seconds)
    } else {
        duration = try await asset.load(.duration)
    }
    let times = try await KeyframeIndex.keyframeTimes(
        track: track, in: CMTimeRange(start: start, duration: duration)
    )
    print("区间内关键帧 \(times.count) 个:")
    for (index, keyframe) in times.enumerated() {
        print(String(format: "  [%3d] %8.3f s", index, keyframe.seconds))
    }
    if times.count > 1 {
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0).seconds }
        let average = gaps.reduce(0, +) / Double(gaps.count)
        print(String(format: "平均间隔 %.3f s（裁剪起点最多会被往前吸附这么多）", average))
    }
}

/// 阶段切换时打一行，避免同一阶段刷屏。
final class StageReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: LivePhotoStage?
    func report(_ stage: LivePhotoStage) {
        lock.lock(); defer { lock.unlock() }
        guard last != stage else { return }
        last = stage
        FileHandle.standardError.write(Data("▸ \(stage.rawValue)…\n".utf8))
    }
}

func runConvert(_ args: Args) async throws {
    guard let path = args.positional.first else { fail("缺少视频路径\n\n" + usage) }

    let cover: CoverSelection
    let coverArg = args.flags["cover"] ?? "auto"
    if coverArg == "auto" || coverArg == "true" {
        cover = .automatic(sampleCount: 24)
    } else if let seconds = Timecode.parse(coverArg) {
        cover = .manual(time: time(seconds))
    } else {
        fail("--cover 只接受秒数或 auto，收到: \(coverArg)")
    }

    guard let format = CoverImageFormat(rawValue: args.flags["format"] ?? "heic") else {
        fail("--format 只接受 heic 或 jpeg")
    }

    let workDirectory = args.flags["out"].map(url)
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("VideoToLive", isDirectory: true)

    let request = ConversionRequest(
        sourceURL: url(path),
        start: time(args.double("start") ?? 0),
        duration: time(args.double("duration") ?? 3),
        cover: cover,
        coverFormat: format,
        coverQuality: args.double("quality") ?? 1.0,
        keepAudio: !args.bool("no-audio"),
        preciseTrim: args.bool("precise"),
        workDirectory: workDirectory,
        importToLibrary: !args.bool("no-import")
    )

    let reporter = StageReporter()
    let result = try await LivePhotoConverter.convert(request) { stage, _ in
        reporter.report(stage)
    }

    print("""

    ── 完成 ──────────────────────────────
    identifier   \(result.identity.value)
    源文件       \(result.info.url.lastPathComponent)  \(result.info.videoCodec)  \
    \(Int(result.info.naturalSize.width))×\(Int(result.info.naturalSize.height))
    转换模式     \(result.remux.didPassthrough ? "无损直通（未重编码）" : "重编码")
    """)
    print(String(format: "裁剪区间     %.3f s → %.3f s（请求起点 %.3f s）",
                 result.remux.actualStart.seconds, result.remux.actualEnd.seconds,
                 request.start.seconds))
    if result.remux.didPassthrough {
        let drift = result.remux.actualStart.seconds - request.start.seconds
        if abs(drift) > 0.001 {
            print(String(format: "             起点被吸附到关键帧，前移了 %.3f s", -drift))
        }
    }
    print(String(format: "封面帧       %.3f s%@", result.coverTime.seconds,
                 result.coverSharpness.map { String(format: "  清晰度 %.1f", $0) } ?? ""))
    print("音轨         \(result.remux.wroteAudio ? "已保留" : "未写入")")
    print("封面         \(result.photoURL.path)  \(megabytes(result.photoSize))")
    print("视频         \(result.videoURL.path)  \(megabytes(result.remux.outputSize))")
    print("合计         \(megabytes(result.totalSize))")
    if let importResult = result.importResult {
        print("图库资产     \(importResult.localIdentifier)")
        print("mediaSubtypes \(importResult.mediaSubtypes.joined(separator: ", "))")
        print("是 Live Photo \(importResult.isLivePhoto ? "是 ✅" : "否 ❌")")
    } else {
        print("图库         已跳过（--no-import）")
    }
}

func runVerify(_ args: Args) async throws {
    guard let moviePath = args.positional.first else { fail("缺少 MOV 路径\n\n" + usage) }
    let movieURL = url(moviePath)
    let asset = AVURLAsset(url: movieURL)

    let metadata = try await asset.load(.metadata)
    let identifier = metadata.first {
        $0.identifier?.rawValue == QuickTimeMetadata.contentIdentifierID
    }
    print("MOV  \(movieURL.lastPathComponent)")
    if let value = try await identifier?.load(.stringValue) {
        print("  content.identifier   \(value) ✅")
    } else {
        print("  content.identifier   缺失 ❌")
    }

    // 直接把定时元数据轨的样本读出来。只看 format description 的扩展不可靠，
    // key 名藏在 mebx 的二进制 keys 表里。
    var stillImageTimes: [CMTime] = []
    let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
    for track in metadataTracks {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { continue }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        guard reader.startReading() else { continue }
        while let group = adaptor.nextTimedMetadataGroup() {
            for item in group.items
            where item.identifier?.rawValue == QuickTimeMetadata.stillImageTimeID {
                stillImageTimes.append(group.timeRange.start)
            }
        }
        reader.cancelReading()
    }
    if let first = stillImageTimes.first {
        print(String(format: "  still-image-time 轨  存在 ✅  静止帧 @ %.3f s（共 %d 条）",
                     first.seconds, stillImageTimes.count))
    } else {
        print("  still-image-time 轨  缺失 ❌")
    }

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    if let track = videoTracks.first {
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let rate = try await track.load(.estimatedDataRate)
        let codec = try await track.load(.formatDescriptions).first
            .map { VideoInspector.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "未知"
        print(String(format: "  视频轨               %@  %d×%d  %.3f fps  %.2f Mbps",
                     codec, Int(size.width), Int(size.height), fps, rate / 1_000_000))
    }

    if args.positional.count > 1 {
        let photoURL = url(args.positional[1])
        if let value = CoverFrameExtractor.readAssetIdentifier(from: photoURL) {
            print("封面 \(photoURL.lastPathComponent)")
            print("  MakerApple[\"17\"]     \(value) ✅")
            if let movieIdentifier = try await identifier?.load(.stringValue) {
                print("  与 MOV 配对          \(movieIdentifier == value ? "一致 ✅" : "不一致 ❌")")
            }
        } else {
            print("封面 \(photoURL.lastPathComponent)")
            print("  MakerApple[\"17\"]     缺失 ❌")
        }
    }
}

func runFrames(_ args: Args) async throws {
    guard let path = args.positional.first else { fail("缺少视频路径\n\n" + usage) }
    let asset = AVURLAsset(url: url(path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        fail("文件里没有视频轨")
    }
    let fps = Double(try await track.load(.nominalFrameRate))
    guard fps > 0 else { fail("拿不到帧率") }

    let startSeconds = args.double("at") ?? 0
    let count = Int(args.double("count") ?? 5)
    let step = 1.0 / fps

    print(String(format: "帧率 %.3f fps，单帧步长 %.6f s", fps, step))
    var previousFingerprint: String?
    var duplicates = 0
    for index in 0..<count {
        let requested = time(startSeconds + Double(index) * step)
        let frame = try await CoverFrameExtractor.extract(from: asset, at: requested)
        let fingerprint = pixelFingerprint(frame.image)
        let repeated = fingerprint == previousFingerprint
        if repeated { duplicates += 1 }
        print(String(format: "  #%02d 请求 %.6f s → 实际 %.6f s  指纹 %@  %@",
                     index, requested.seconds, frame.actualTime.seconds,
                     fingerprint, repeated ? "⚠️ 与上一帧相同" : "✅ 画面已变化"))
        previousFingerprint = fingerprint
    }
    print(duplicates == 0
          ? "\n结论：\(count) 帧全部互不相同，帧精确抽取成立 ✅"
          : "\n结论：出现 \(duplicates) 次重复帧 ❌")
}

/// 对图像做低成本采样指纹，只用来判断「两帧是否是同一画面」。
func pixelFingerprint(_ image: CGImage) -> String {
    guard let data = image.dataProvider?.data as Data? else { return "?" }
    var hash: UInt64 = 0xcbf29ce484222325
    let stride = max(1, data.count / 4096)
    for index in Swift.stride(from: 0, to: data.count, by: stride) {
        hash = (hash ^ UInt64(data[index])) &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

func runStress(_ args: Args) async throws {
    guard let path = args.positional.first else { fail("缺少视频路径\n\n" + usage) }
    let times = Int(args.double("times") ?? 20)
    let seconds = args.double("duration") ?? 3
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VideoToLiveStress", isDirectory: true)
    try? FileManager.default.removeItem(at: workDirectory)

    print("连续转换 \(times) 次，每次 \(seconds) s 片段，不写图库")
    var baseline: Int64 = 0
    for index in 0..<times {
        let request = ConversionRequest(
            sourceURL: url(path),
            start: time(Double(index % 5)),
            duration: time(seconds),
            cover: .automatic(sampleCount: 24),
            workDirectory: workDirectory,
            importToLibrary: false
        )
        _ = try await LivePhotoConverter.convert(request)
        // 产物立刻清掉，只留内存曲线
        try? FileManager.default.removeItem(at: workDirectory)
        let rss = residentBytes()
        if index == 0 { baseline = rss }
        print(String(format: "  [%2d/%d] 常驻内存 %.1f MB  相对首次 %+.1f MB",
                     index + 1, times, Double(rss) / 1_048_576,
                     Double(rss - baseline) / 1_048_576))
    }
}

func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

/// 时间码解析自检。界面输入框与 CLI 共用这套规则，这里一次跑完。
func runTimecodeSelfTest() {
    let cases: [(String, Double?)] = [
        ("0", 0), ("12.5", 12.5), ("90", 90),
        ("1:02.5", 62.5), ("1:2", 62), ("0:00.00", 0),
        ("01:02:03", 3723), ("1:00:00", 3600),
        ("", nil), ("abc", nil), ("1:2:3:4", nil),
        ("-5", nil), ("1:75", nil), ("2:60", nil),
    ]
    var failed = 0
    for (input, expected) in cases {
        let actual = Timecode.parse(input)
        let ok: Bool
        switch (actual, expected) {
        case (nil, nil): ok = true
        case (let a?, let e?): ok = abs(a - e) < 0.0001
        default: ok = false
        }
        if !ok { failed += 1 }
        print(String(format: "  %@ %-10@ → %@（期望 %@）",
                     ok ? "✅" : "❌", input as NSString,
                     actual.map { String($0) } ?? "nil",
                     expected.map { String($0) } ?? "nil"))
    }
    print(failed == 0 ? "\n全部通过" : "\n\(failed) 条不通过")
    if failed > 0 { exit(1) }
}

// MARK: - 入口

let raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { print(usage); exit(0) }
let args = Args(Array(raw.dropFirst()))

do {
    switch command {
    case "inspect":   try await runInspect(args)
    case "keyframes": try await runKeyframes(args)
    case "convert":   try await runConvert(args)
    case "frames":    try await runFrames(args)
    case "stress":    try await runStress(args)
    case "verify":    try await runVerify(args)
    case "timecode":  runTimecodeSelfTest()
    case "-h", "--help", "help": print(usage)
    default: fail("未知命令: \(command)\n\n" + usage)
    }
} catch let error as LivePhotoError {
    fail("\n✗ 失败\n" + error.description)
} catch {
    fail("\n✗ 失败: \(error)")
}
