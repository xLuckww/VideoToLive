import VideoToLiveCore
import SwiftUI

/// 窗口外壳：没有视频时整窗是拖放区；有视频时是「顶栏 + 预览/侧栏 + 时间轴」的剪辑布局。
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            if model.info == nil {
                EmptyStateView(model: model)
            } else {
                editor
            }
        }
        .foregroundStyle(Theme.text)
        .dropDestination(for: URL.self) { urls, _ in
            model.accept(urls: urls)
            return true
        } isTargeted: { targeted in
            model.isTargeted = targeted
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TopBar(model: model)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                PreviewCanvas(model: model)
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                InspectorSidebar(model: model)
                    .frame(width: 264)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            TimelineDock(model: model)
        }
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - 顶栏

/// 替代系统标题栏：文件名、模式徽标、主操作。左侧给红绿灯留出位置。
struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 10) {
                if let info = model.info {
                    Text(info.url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if info.mode.isPassthrough {
                        Pill(text: "无损直通")
                    } else {
                        Pill(text: "需重编码", foreground: Theme.warning, background: Theme.warningSoft)
                    }
                }
                Spacer(minLength: 16)
                Button("换一个") { model.reset() }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(model.phase == .converting)
                Button(model.phase == .finished ? "再生成一次" : "生成 Live Photo") {
                    model.convert()
                }
                .buttonStyle(PrimaryButtonStyle(enabled: model.canConvert))
                .disabled(!model.canConvert)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(Theme.window)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                Text("VideoToLive")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .allowsHitTesting(false)
            }
            .frame(height: 52)

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accentSoft).frame(width: 96, height: 96)
                    Image(systemName: "livephoto")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: 6) {
                    Text("把视频拖到这里")
                        .font(.system(size: 20, weight: .medium))
                    Text("支持 MP4、MOV、M4V · 视频轨无损转成 Live Photo")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                if model.phase == .inspecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("正在解析…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(height: 30)
                } else {
                    Button("选择视频") { model.presentOpenPanel() }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(height: 30)
                }
                if let failure = model.failure {
                    Label(failure.reason, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(model.isTargeted ? Theme.accentSoft.opacity(0.6) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        model.isTargeted ? Theme.accent : Theme.border,
                        style: StrokeStyle(lineWidth: model.isTargeted ? 1.5 : 1, dash: [6, 5])
                    )
            )
            .padding([.horizontal, .bottom], 24)
            .animation(.easeOut(duration: 0.15), value: model.isTargeted)
        }
        .ignoresSafeArea(edges: .top)
    }
}
