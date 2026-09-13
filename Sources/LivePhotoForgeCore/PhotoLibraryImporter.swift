import Foundation
import Photos
#if canImport(AppKit)
import AppKit
#endif
public struct ImportResult: Sendable {
    public let localIdentifier: String
    public let isLivePhoto: Bool
    public let mediaSubtypes: [String]
}

public enum PhotoLibraryImporter {

    public static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }

    /// 配对写入。两个资源必须挂在同一个 PHAssetCreationRequest 下，
    /// 且携带同一个 identifier，否则「照片」会拆成两个独立资产（方案 5.3）。
    public static func importLivePhoto(
        photoURL: URL,
        videoURL: URL
    ) async throws -> ImportResult {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw LivePhotoError(.importLibrary,
                "没有照片图库写入权限（当前状态 \(describe(status))）。请在「系统设置 → 隐私与安全性 → 照片」中允许。")
        }

        var placeholderID: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
                placeholderID = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw LivePhotoError(.importLibrary, "写入照片图库被拒绝", underlying: error)
        }

        guard let placeholderID else {
            throw LivePhotoError(.importLibrary, "写入成功但没拿到资产标识，无法回读校验")
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [placeholderID], options: nil)
        guard let asset = fetch.firstObject else {
            throw LivePhotoError(.importLibrary, "写入后回查资产失败：\(placeholderID)")
        }
        return ImportResult(
            localIdentifier: placeholderID,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            mediaSubtypes: describe(asset.mediaSubtypes)
        )
    }

    /// 方案 4.4：写入成功后提供「在照片中显示」。
    public static func revealInPhotos(localIdentifier: String) {
        let assetID = localIdentifier.components(separatedBy: "/").first ?? localIdentifier
        if let url = URL(string: "photos://asset?assetUUID=\(assetID)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "未决定"
        case .restricted:    return "受限"
        case .denied:        return "已拒绝"
        case .authorized:    return "已授权"
        case .limited:       return "部分授权"
        @unknown default:    return "未知"
        }
    }

    private static func describe(_ subtypes: PHAssetMediaSubtype) -> [String] {
        var names: [String] = []
        if subtypes.contains(.photoLive)     { names.append(".photoLive") }
        if subtypes.contains(.photoHDR)      { names.append(".photoHDR") }
        if subtypes.contains(.photoPanorama) { names.append(".photoPanorama") }
        if subtypes.contains(.photoScreenshot) { names.append(".photoScreenshot") }
        if subtypes.contains(.videoHighFrameRate) { names.append(".videoHighFrameRate") }
        return names.isEmpty ? ["（无）"] : names
    }
}
