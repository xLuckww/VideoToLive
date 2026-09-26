import AVFoundation
import CoreMedia
import Foundation

/// 导入后要立刻展示的信息（方案 4.1）。
public struct VideoInfo: Sendable {
    public let url: URL
    public let duration: CMTime
    public let naturalSize: CGSize        // 已应用 preferredTransform 后的显示尺寸
    public let nominalFrameRate: Float
    public let videoCodec: String
    public let audioCodec: String?
    public let fileSize: Int64
    public let videoBitrate: Float        // bps，来自轨道的 estimatedDataRate
    public let preferredTransform: CGAffineTransform
    public let mode: ConversionMode

    public var durationSeconds: Double { duration.seconds }

    public var summary: String {
        var lines = [
            "文件      \(url.lastPathComponent)",
            String(format: "时长      %.3f s", durationSeconds),
            "分辨率    \(Int(naturalSize.width))×\(Int(naturalSize.height))",
            String(format: "帧率      %.3f fps", nominalFrameRate),
            "视频编码  \(videoCodec)",
            "音频编码  \(audioCodec ?? "（无音轨）")",
            String(format: "视频码率  %.2f Mbps", videoBitrate / 1_000_000),
            String(format: "文件大小  %.2f MB", Double(fileSize) / 1_048_576),
            "转换模式  \(mode.badge)",
        ]
        if let why = mode.reason { lines.append("重编码原因 \(why)") }
        return lines.joined(separator: "\n")
    }
}

/// 转换模式徽标（方案 4.1）。
public enum ConversionMode: Sendable, Equatable {
    case passthrough              // 无损直通
    case reencode(reason: String) // 需重编码
    /// 编码格式能直通，但画面是原生竖屏存储（编码尺寸高大于宽、没有旋转标记）。
    /// 这样的实况在 iPhone 上播放会发糊，而 iPhone 自己拍的竖屏实况是横屏存储
    /// 加 90° 旋转标记。改存储方向只能重编码。
    case portraitReencode

    public var badge: String {
        switch self {
        case .passthrough:      return "无损直通"
        case .reencode:         return "需重编码"
        case .portraitReencode: return "竖屏重编码"
        }
    }

    public var reason: String? {
        switch self {
        case .passthrough:             return nil
        case .reencode(let reason):    return reason
        case .portraitReencode:
            return "原生竖屏存储的视频在 iPhone 上播放实况会发糊，将转为横屏存储加旋转标记，视频会以原位深、帧率和码率重新编码"
        }
    }

    public var isPassthrough: Bool { self == .passthrough }
}

public enum VideoInspector {

    /// MOV 容器能原样承载的视频编码。其余编码（VP9 / AV1 等）只能重编码。
    private static let passthroughVideoCodecs: Set<FourCharCode> = [
        kCMVideoCodecType_H264,
        kCMVideoCodecType_HEVC,
        kCMVideoCodecType_HEVCWithAlpha,
        kCMVideoCodecType_AppleProRes422,
        kCMVideoCodecType_AppleProRes422HQ,
        kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy,
        kCMVideoCodecType_AppleProRes4444,
        kCMVideoCodecType_AppleProRes4444XQ,
    ]

    public static func inspect(url: URL) async throws -> VideoInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LivePhotoError(.inspect, "文件不存在: \(url.path)")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw LivePhotoError(.inspect, "无法读取媒体信息，文件可能损坏或格式不受支持", underlying: error)
        }

        guard let videoTrack = videoTracks.first else {
            throw LivePhotoError(.inspect, "文件里没有视频轨")
        }

        let (size, transform, fps, dataRate) = try await (
            videoTrack.load(.naturalSize),
            videoTrack.load(.preferredTransform),
            videoTrack.load(.nominalFrameRate),
            videoTrack.load(.estimatedDataRate)
        )
        let displaySize = size.applying(transform)
        let videoCodecType = try await codecType(of: videoTrack)
        let audioCodecType: FourCharCode? = audioTracks.isEmpty
            ? nil : try await codecType(of: audioTracks[0])

        let mode: ConversionMode
        if let videoCodecType, passthroughVideoCodecs.contains(videoCodecType) {
            mode = needsLandscapeStorage(codedSize: size, transform: transform)
                ? .portraitReencode : .passthrough
        } else {
            let name = videoCodecType.map(fourCC) ?? "未知"
            mode = .reencode(reason: "视频编码 \(name) 不能原样封进 MOV 容器")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        return VideoInfo(
            url: url,
            duration: duration,
            naturalSize: CGSize(width: abs(displaySize.width), height: abs(displaySize.height)),
            nominalFrameRate: fps,
            videoCodec: videoCodecType.map(fourCC) ?? "未知",
            audioCodec: audioCodecType.map(fourCC),
            fileSize: fileSize,
            videoBitrate: dataRate,
            preferredTransform: transform,
            mode: mode
        )
    }

    /// 原生竖屏存储：编码尺寸高大于宽，且变换里没有 90° 旋转。
    /// iPhone 拍的竖屏是横屏存储加旋转标记，不算在内。
    public static func needsLandscapeStorage(codedSize: CGSize, transform: CGAffineTransform) -> Bool {
        let rotated90 = abs(transform.b) > 0.5 || abs(transform.c) > 0.5
        return !rotated90 && abs(codedSize.height) > abs(codedSize.width)
    }

    private static func codecType(of track: AVAssetTrack) async throws -> FourCharCode? {
        let descriptions = try await track.load(.formatDescriptions)
        guard let desc = descriptions.first else { return nil }
        return CMFormatDescriptionGetMediaSubType(desc)
    }

    public static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),  UInt8(code & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? "????"
        switch text {
        case "avc1": return "H.264 (avc1)"
        case "hvc1", "hev1": return "HEVC (\(text))"
        case "mp4a": return "AAC (mp4a)"
        case "lpcm": return "PCM (lpcm)"
        default: return text
        }
    }
}
