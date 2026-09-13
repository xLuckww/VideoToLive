import AVFoundation
import AppKit
import SwiftUI

/// 承载 AVPlayerLayer 的 NSView。SwiftUI 没有现成的无控件播放视图，
/// 用 VideoPlayer 会带上系统自己的播放条，跟我们的时间轴打架。
final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
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

/// 时间轴上方的预览窗。让用户看清当前起点落在视频的哪一帧，
/// 并能直接把选中的片段播一遍。
struct PreviewMonitor: View {
    @ObservedObject var model: AppModel

    /// 源视频宽高比。naturalSize 已经应用过 preferredTransform，
    /// 竖屏素材拿到的就是 2160×3840 这样的竖向尺寸。
    private var sourceAspect: Double {
        guard let size = model.info?.naturalSize, size.width > 0, size.height > 0 else {
            return 16.0 / 9.0
        }
        return size.width / size.height
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                PlayerSurface(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            // 按源视频比例定形，竖屏素材就竖着显示，不再留两边的大黑边。
            .aspectRatio(sourceAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 460)
            .overlay(alignment: .topTrailing) { anchorBadge }

            controls
        }
    }

    private var anchorBadge: some View {
        Text(model.previewAnchor == .start ? "起点" : "终点")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
            .foregroundStyle(.white)
            .padding(8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlaySelection()
            } label: {
                Label(model.isPlaying ? "停止" : "播放选段",
                      systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                    .frame(minWidth: 78)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.player == nil)

            Text(AppModel.timecode(model.playheadTime))
                .font(.caption.monospacedDigit())
            Text("/")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(AppModel.timecode(model.maxDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Text(String(format: "选段 %@ – %@",
                        AppModel.timecode(model.selectionStart),
                        AppModel.timecode(model.selectionEnd)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
