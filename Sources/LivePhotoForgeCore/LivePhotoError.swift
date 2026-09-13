import Foundation

/// 生成 Live Photo 的四个阶段，对应方案 4.4 的进度条。
/// 失败时必须能说清是哪一环节出的问题，而不是只报「转换失败」。
public enum LivePhotoStage: String, Sendable, CaseIterable {
    case inspect        = "解析视频"
    case extractCover   = "抽帧"
    case encodeCover    = "编码封面"
    case remux          = "封装视频"
    case importLibrary  = "写入图库"
}

public struct LivePhotoError: LocalizedError, CustomStringConvertible {
    public let stage: LivePhotoStage
    public let reason: String
    public let underlying: Error?

    public init(_ stage: LivePhotoStage, _ reason: String, underlying: Error? = nil) {
        self.stage = stage
        self.reason = reason
        self.underlying = underlying
    }

    public var description: String {
        var text = "[\(stage.rawValue)] \(reason)"
        if let underlying {
            text += "\n  └ 底层错误: \(underlying.localizedDescription)"
        }
        return text
    }

    public var errorDescription: String? { description }
}
