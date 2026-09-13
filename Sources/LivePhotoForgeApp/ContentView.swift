import LivePhotoForgeCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    switch model.phase {
                    case .empty:
                        DropZone(isTargeted: model.isTargeted)
                    case .inspecting:
                        ProgressView("解析中…")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .ready, .converting, .finished, .failed:
                        if let info = model.info {
                            InfoCard(info: info)
                        }
                        if model.info != nil, model.phase != .converting {
                            TrimPanel(model: model)
                        }
                        if model.phase == .converting {
                            StageProgress(stage: model.stage, fraction: model.stageProgress)
                        }
                        if let result = model.result, model.phase == .finished {
                            ResultCard(result: result) { model.revealInPhotos() }
                        }
                        if let failure = model.failure {
                            FailureCard(failure: failure)
                        }
                        if model.showsSharingCaveat {
                            CaveatNote(
                                text: "这是 4K 素材。存进本地相册没问题，但发到微信、小红书等平台时，对方服务器会重新压缩。"
                            )
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.accept(urls: urls)
            return true
        } isTargeted: { targeted in
            model.isTargeted = targeted
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "livephoto")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("LivePhotoForge").font(.headline)
                Text("视频转 Live Photo，视频轨无损").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase != .empty {
                Button("换一个") { model.reset() }
                    .buttonStyle(.link)
                    .disabled(model.phase == .converting)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.phase == .ready || model.phase == .finished,
               let estimate = model.estimatedSize {
                Text(String(format: "自动挑选最清晰的一帧作封面 · 预估约 %.1f MB",
                            Double(estimate) / 1_048_576))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { model.convert() }) {
                Text(model.phase == .finished ? "再生成一次" : "生成 Live Photo")
                    .frame(minWidth: 120)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canConvert)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var canConvert: Bool {
        guard model.info != nil else { return false }
        return model.phase == .ready || model.phase == .finished
            || (model.phase == .failed && model.info != nil)
    }
}

// MARK: - 拖放区

struct DropZone: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("把视频拖到这里")
                .font(.title3)
            Text("支持 MP4 / MOV / M4V · 也可以按 ⌘O 选择文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                )
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

// MARK: - 视频信息

struct InfoCard: View {
    let info: VideoInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(info.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ModeBadge(mode: info.mode)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                row("时长", String(format: "%.2f s", info.durationSeconds))
                row("分辨率", "\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height))")
                row("帧率", String(format: "%.2f fps", info.nominalFrameRate))
                row("视频编码", info.videoCodec)
                row("音频编码", info.audioCodec ?? "无音轨")
                row("文件大小", String(format: "%.1f MB", Double(info.fileSize) / 1_048_576))
            }
            if case .reencode(let reason) = info.mode {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

struct ModeBadge: View {
    let mode: ConversionMode

    var body: some View {
        Text(mode.badge)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(mode.isPassthrough
                               ? Color.green.opacity(0.15) : Color.orange.opacity(0.18))
            )
            .foregroundStyle(mode.isPassthrough ? Color.green : Color.orange)
    }
}

// MARK: - 进度

struct StageProgress: View {
    let stage: LivePhotoStage?
    let fraction: Double

    private var stages: [LivePhotoStage] {
        [.extractCover, .encodeCover, .remux, .importLibrary]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stage?.rawValue ?? "准备中").font(.callout)
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(stages, id: \.self) { item in
                    Capsule()
                        .fill(fill(for: item))
                        .frame(height: 4)
                }
            }
            HStack(spacing: 0) {
                ForEach(stages, id: \.self) { item in
                    Text(item.rawValue)
                        .font(.caption2)
                        .foregroundStyle(item == stage ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func fill(for item: LivePhotoStage) -> Color {
        guard let stage, let current = stages.firstIndex(of: stage),
              let index = stages.firstIndex(of: item) else {
            return Color.secondary.opacity(0.2)
        }
        if index < current { return .accentColor }
        if index == current { return .accentColor.opacity(0.45) }
        return Color.secondary.opacity(0.2)
    }
}

// MARK: - 结果

struct ResultCard: View {
    let result: ConversionResult
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(result.importResult?.isLivePhoto == true
                     ? "已写入照片图库" : "已生成，但系统未识别为 Live Photo")
                    .font(.headline)
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                GridRow {
                    Text("转换模式").font(.callout).foregroundStyle(.secondary)
                    Text(result.remux.didPassthrough ? "无损直通（视频轨未重编码）" : "重编码")
                        .font(.callout)
                }
                GridRow {
                    Text("实际区间").font(.callout).foregroundStyle(.secondary)
                    Text(String(format: "%.2f – %.2f s",
                                result.remux.actualStart.seconds, result.remux.actualEnd.seconds))
                        .font(.callout.monospacedDigit())
                }
                GridRow {
                    Text("封面帧").font(.callout).foregroundStyle(.secondary)
                    Text(String(format: "%.2f s", result.coverTime.seconds))
                        .font(.callout.monospacedDigit())
                }
                GridRow {
                    Text("成品体积").font(.callout).foregroundStyle(.secondary)
                    Text(String(format: "%.1f MB（封面 %.1f + 视频 %.1f）",
                                Double(result.totalSize) / 1_048_576,
                                Double(result.photoSize) / 1_048_576,
                                Double(result.remux.outputSize) / 1_048_576))
                        .font(.callout.monospacedDigit())
                }
            }
            if let subtypes = result.importResult?.mediaSubtypes {
                Text("mediaSubtypes: " + subtypes.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button(action: reveal) {
                Label("在照片中显示", systemImage: "photo.on.rectangle")
            }
            .disabled(result.importResult == nil)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.07)))
    }
}

// MARK: - 失败与说明

struct FailureCard: View {
    let failure: LivePhotoError

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("在「\(failure.stage.rawValue)」这一步失败").font(.headline)
                Spacer()
            }
            Text(failure.reason).font(.callout)
            if let underlying = failure.underlying {
                Text(underlying.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.09)))
    }
}

struct CaveatNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
