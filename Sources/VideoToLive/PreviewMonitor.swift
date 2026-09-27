import AVFoundation
import AppKit
import VideoToLiveCore
import SwiftUI

/// 承载 AVPlayerLayer 的 NSView。SwiftUI 的 VideoPlayer 自带系统播放条，
/// 会跟时间轴抢操作，所以自己包一层。
final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("不从 xib 加载") }

    override func layout() {
        super.layout()
        // 关掉隐式动画，否则窗口缩放时画面会飘
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

/// 中间的预览画布。画面按源视频比例尽量放大，生成进度与结果都浮在画布上。
struct PreviewCanvas: View {
    @ObservedObject var model: AppModel

    /// naturalSize 已应用 preferredTransform，竖屏素材拿到的就是竖向尺寸。
    private var sourceAspect: Double {
        guard let size = model.info?.naturalSize, size.width > 0, size.height > 0 else {
            return 16.0 / 9.0
        }
        return size.width / size.height
    }

    var body: some View {
        ZStack {
            Theme.canvas

            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xD5E0EA))
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .aspectRatio(sourceAspect, contentMode: .fit)
            .overlay(alignment: .topLeading) { anchorBadge }
            .padding(24)

            VStack {
                if model.phase == .finished, let result = model.result {
                    ResultBanner(result: result,
                                 reveal: { model.revealInPhotos() },
                                 dismiss: { model.dismissResult() })
                }
                if model.phase == .failed, let failure = model.failure {
                    FailureBanner(failure: failure, dismiss: { model.dismissResult() })
                }
                Spacer()
            }
            .padding(16)

            if model.phase == .converting {
                ConversionProgressCard(stage: model.stage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var anchorBadge: some View {
        HStack(spacing: 4) {
            Text(model.previewAnchor == .start ? "起点" : "终点")
                .font(.system(size: 11, weight: .medium))
            Text(AppModel.timecode(model.playheadTime))
                .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.9)))
        .padding(8)
    }
}

// MARK: - 浮层

struct ConversionProgressCard: View {
    let stage: LivePhotoStage?

    private let stages: [LivePhotoStage] = [.extractCover, .encodeCover, .remux, .importLibrary]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Theme.accent)
                Text("正在\(stage?.rawValue ?? "准备")…")
                    .font(.system(size: 13, weight: .medium))
            }
            HStack(spacing: 6) {
                ForEach(stages, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(fill(for: item)).frame(height: 4)
                        Text(item.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(item == stage ? Theme.text : Theme.textMuted)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private func fill(for item: LivePhotoStage) -> Color {
        guard let stage, let current = stages.firstIndex(of: stage),
              let index = stages.firstIndex(of: item) else { return Theme.hairline }
        if index < current { return Theme.accent }
        if index == current { return Theme.accent.opacity(0.45) }
        return Theme.hairline
    }
}

struct ResultBanner: View {
    let result: ConversionResult
    let reveal: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 30, height: 30)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.importResult?.isLivePhoto == true
                     ? "已写入照片图库" : "已生成，但系统未识别为 Live Photo")
                    .font(.system(size: 13, weight: .medium))
                Text(String(format: "%@ – %@ · %.1f MB · %@",
                            AppModel.timecode(result.remux.actualStart.seconds),
                            AppModel.timecode(result.remux.actualEnd.seconds),
                            Double(result.totalSize) / 1_048_576,
                            result.remux.didPassthrough ? "视频轨未重编码" : "已重编码"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Button("在照片中显示", action: reveal)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(result.importResult == nil)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

struct FailureBanner: View {
    let failure: LivePhotoError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("在「\(failure.stage.rawValue)」这一步失败")
                    .font(.system(size: 13, weight: .medium))
                Text(failure.reason)
                    .font(.system(size: 12))
                if let underlying = failure.underlying {
                    Text(underlying.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.dangerSoft))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.danger.opacity(0.25), lineWidth: 0.5))
    }
}
