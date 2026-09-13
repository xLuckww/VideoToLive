import Foundation

/// Live Photo 的配对标识。静态图与 MOV 必须携带同一个字符串，
/// 否则「照片」会把它们当成两个互不相关的资产。
public struct AssetIdentity: Sendable, Hashable {
    public let value: String

    public init(value: String) { self.value = value }

    /// Apple 自家写入的是大写 UUID，这里保持一致。
    public static func generate() -> AssetIdentity {
        AssetIdentity(value: UUID().uuidString.uppercased())
    }
}

public enum QuickTimeMetadata {
    public static let contentIdentifier = "com.apple.quicktime.content.identifier"
    public static let stillImageTime    = "com.apple.quicktime.still-image-time"

    /// `mdta/` 前缀是 QuickTime metadata keyspace 在 AVMetadataIdentifier 里的写法。
    public static let contentIdentifierID = "mdta/" + contentIdentifier
    public static let stillImageTimeID    = "mdta/" + stillImageTime
}

public enum AppleMakerNote {
    /// Apple Maker Note 里承载 asset identifier 的键。
    public static let assetIdentifierKey = "17"
}
