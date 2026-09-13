import LivePhotoForgeCore
import SwiftUI

/// 右侧栏：封面 → 时长 → 视频信息。封面放最上面，它是用户最关心的结果。
struct InspectorSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            coverSection
            divider
            durationSection
            divider
            infoSection
            Spacer(minLength: 0)
            if model.showsSharingCaveat {
                Label("4K 存进本地相册没问题，发到微信、小红书等平台时会被对方重新压缩。",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 0.5)
    }

    // MARK: 封面

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "封面")
                Spacer()
                if let time = model.coverTime {
                    Text(AppModel.timecode(time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.canvas)
                if let image = model.coverPreview {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
                if model.isPickingCover {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                }
            }
            .frame(height: 168)
            .clipped()
            .overlay(alignment: .topLeading) {
                Text("LIVE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.92)))
                    .padding(10)
            }
            Text("自动挑选片段里最清晰的一帧")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: 时长

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "时长")
                Spacer()
                Text(String(format: "%.2f s", model.selectionDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            SegmentedChoice(
                options: model.availablePresets,
                label: { $0 == 1.5 ? "1.5s" : "\(Int($0))s" },
                isSelected: { model.isPresetActive($0) },
                onSelect: { model.applyPreset($0) }
            )
        }
    }

    // MARK: 视频信息

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "视频")
            if let info = model.info {
                VStack(alignment: .leading, spacing: 4) {
                    infoLine(String(format: "%d×%d · %.2f fps",
                                    Int(info.naturalSize.width), Int(info.naturalSize.height),
                                    info.nominalFrameRate))
                    infoLine("\(shortCodec(info.videoCodec)) · \(shortCodec(info.audioCodec ?? "无音轨"))")
                    infoLine(String(format: "%@ · %.1f MB",
                                    AppModel.timecode(info.durationSeconds),
                                    Double(info.fileSize) / 1_048_576))
                }
                if let estimate = model.estimatedSize {
                    HStack {
                        Text("预估成品")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "≈ %.1f MB", Double(estimate) / 1_048_576))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .padding(.top, 4)
                }
                if case .reencode(let reason) = info.mode {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func infoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
    }

    /// "HEVC (hvc1)" → "HEVC"，侧栏里不需要 fourCC。
    private func shortCodec(_ name: String) -> String {
        name.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) ?? name
    }
}
