import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CoverImageFormat: String, Sendable, CaseIterable {
    case heic, jpeg

    var utType: UTType { self == .heic ? .heic : .jpeg }
    var fileExtension: String { self == .heic ? "heic" : "jpg" }

    /// HEIC 质量一旦取到 1.0，ImageIO 会改用 4:4:4 的 HEVC Range Extensions 编码。
    /// Mac 能软解，但 iPhone 解不了，iCloud 同步后提示「加载此照片的更高质量版本时出错」，
    /// 只能播放低清的预览版本。0.99 仍是标准 4:2:0 Main / Main 10。
    var maxQuality: Double { self == .heic ? 0.99 : 1.0 }
}

public struct CoverFrame: Sendable {
    public let image: CGImage
    /// 实际抽到的帧时间。容差设为 .zero 后它应当与请求时间落在同一帧内。
    public let actualTime: CMTime
    public let requestedTime: CMTime
}

public enum CoverFrameExtractor {

    /// 帧精确抽帧。两端容差必须显式设为 .zero，否则会拿到邻近帧，
    /// 手动模式下会表现为「按了方向键画面没变」（方案 5.4 / 九、次要风险）。
    public static func makeGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    public static func extract(from asset: AVAsset, at time: CMTime) async throws -> CoverFrame {
        let generator = makeGenerator(for: asset)
        do {
            let (image, actual) = try await generator.image(at: time)
            return CoverFrame(image: image, actualTime: actual, requestedTime: time)
        } catch {
            throw LivePhotoError(.extractCover,
                String(format: "无法抽取 %.3fs 处的帧", time.seconds), underlying: error)
        }
    }

    /// 自动模式（方案 4.3）：区间内均匀采样，用拉普拉斯方差挑最清晰的一帧。
    public static func pickSharpestFrame(
        from asset: AVAsset,
        in range: CMTimeRange,
        sampleCount: Int = 24
    ) async throws -> (frame: CoverFrame, score: Double) {
        let count = max(2, sampleCount)
        let generator = makeGenerator(for: asset)
        // 抽样只为评分，缩到 720 宽足够，也顺带压住 4K 素材的内存峰值。
        generator.maximumSize = CGSize(width: 720, height: 720)

        var times: [CMTime] = []
        for index in 0..<count {
            let ratio = Double(index) / Double(count - 1)
            let offset = CMTimeMultiplyByFloat64(range.duration, multiplier: ratio)
            times.append(range.start + offset)
        }

        var best: (time: CMTime, score: Double)?
        for time in times {
            guard let (image, actual) = try? await generator.image(at: time) else { continue }
            let score = SharpnessScorer.laplacianVariance(of: image)
            if best == nil || score > best!.score {
                best = (actual, score)
            }
        }
        guard let best else {
            throw LivePhotoError(.extractCover, "区间内一帧都没抽到，视频可能已损坏")
        }
        // 评分用小图，真正的封面按原分辨率重抽一次。
        let frame = try await extract(from: asset, at: best.time)
        return (frame, best.score)
    }

    /// 写静态封面。配对要素之一：asset identifier 塞进 Apple Maker Note 的键 "17"。
    public static func writeStillImage(
        _ frame: CoverFrame,
        identity: AssetIdentity,
        format: CoverImageFormat,
        quality: Double,
        to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil
        ) else {
            throw LivePhotoError(.encodeCover, "系统不支持写出 \(format.rawValue.uppercased()) 封面")
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.0, min(format.maxQuality, quality)),
            kCGImagePropertyMakerAppleDictionary: [
                AppleMakerNote.assetIdentifierKey: identity.value
            ] as CFDictionary,
        ]
        CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoError(.encodeCover, "封面写盘失败：\(url.path)")
        }
    }

    /// 回读校验，确认 identifier 真的落进了 Maker Note。
    public static func readAssetIdentifier(from url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let makerNote = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        else { return nil }
        return makerNote[AppleMakerNote.assetIdentifierKey] as? String
    }
}
