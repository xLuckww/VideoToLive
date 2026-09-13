import LivePhotoForgeCore
import SwiftUI

/// 时间轴：缩略图条 + 关键帧竖线 + 可拖动选区，配起止时间输入框。
struct TrimPanel: View {
    @ObservedObject var model: AppModel

    private let stripHeight: CGFloat = 58
    private let handleWidth: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            filmstrip
            controls
            notices
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 起止输入

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    timeField(
                        label: "起点",
                        text: $model.startInput,
                        onChange: { model.previewStartInput() }
                    )
                    Text("–").foregroundStyle(.secondary)
                    timeField(
                        label: "终点",
                        text: $model.endInput,
                        onChange: { model.previewEndInput() }
                    )
                }
                if model.canStepKeyframes {
                    keyframeStepper
                }
                Text(String(format: "时长 %.2f s", model.selectionDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            coverPreview
        }
    }

    private func timeField(
        label: String,
        text: Binding<String>,
        onChange: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("0:00.00", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .onChange(of: text.wrappedValue) { _ in onChange() }
        }
    }

    /// 吸附模式下起点只能落在关键帧上，给两个按钮直接跳，免得靠拖拽去猜。
    private var keyframeStepper: some View {
        HStack(spacing: 6) {
            Button {
                model.stepToPreviousKeyframe()
            } label: {
                Label("上一关键帧", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .disabled(model.previousKeyframe == nil)

            Button {
                model.stepToNextKeyframe()
            } label: {
                Label("下一关键帧", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .disabled(model.nextKeyframe == nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var coverPreview: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                if let image = model.coverPreview {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 96, height: 62)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if model.isPickingCover {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 62)
            .clipped()
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

            Text(model.coverTime.map { String(format: "封面 %.2f s", $0) } ?? "封面")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 缩略图条

    private var filmstrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = model.maxDuration > 0 ? width / model.maxDuration : 0
            let startX = model.selectionStart * scale
            let selectionWidth = max(handleWidth * 2, model.selectionDuration * scale)

            ZStack(alignment: .topLeading) {
                thumbnailRow
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Color.black.opacity(0.5)
                    .frame(width: max(0, startX), height: stripHeight)
                Color.black.opacity(0.5)
                    .frame(width: max(0, width - startX - selectionWidth), height: stripHeight)
                    .offset(x: startX + selectionWidth)

                keyframeTicks(scale: scale)
                playhead(scale: scale)
                selectionBox(startX: startX, width: selectionWidth, scale: scale)
            }
            .frame(width: width, height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.timelineSpace)
        }
        .frame(height: stripHeight)
    }

    private var thumbnailRow: some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Rectangle().fill(Color.secondary.opacity(0.15))
            } else {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
    }

    /// 关键帧竖线。让用户直观看到裁剪点会吸附到哪里。
    private func keyframeTicks(scale: Double) -> some View {
        ForEach(Array(model.keyframes.enumerated()), id: \.offset) { _, time in
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 1, height: 7)
                .offset(x: time * scale)
        }
    }

    /// 播放头。播放时随画面移动，停着时就停在预览窗当前显示的那一帧。
    private func playhead(scale: Double) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: stripHeight)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .offset(x: model.playheadTime * scale)
            .opacity(model.isPlaying ? 1 : 0.7)
    }

    private func selectionBox(startX: Double, width selectionWidth: Double, scale: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: selectionWidth, height: stripHeight)
                .contentShape(Rectangle())
                .gesture(moveGesture(scale: scale))

            handle(at: 0, scale: scale, isLeading: true)
            handle(at: selectionWidth - handleWidth, scale: scale, isLeading: false)
        }
        .offset(x: startX)
    }

    private func handle(at offset: Double, scale: Double, isLeading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: stripHeight)
            .overlay(Rectangle().fill(Color.white.opacity(0.85)).frame(width: 2, height: 18))
            .offset(x: offset)
            .contentShape(Rectangle())
            .gesture(resizeGesture(scale: scale, isLeading: isLeading))
    }

    // MARK: 手势

    /// 手势坐标必须以整条时间轴为参照。
    /// 选区框自己会跟着拖动移动，若用默认的 .local（以框自身为参照），
    /// 框一动手势的位移读数就被抵消一截，框又被拉回去——表现为来回晃动、只跟一半速度。
    private static let timelineSpace = "timeline"

    private func moveGesture(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.timelineSpace))
            .onChanged { value in
                guard scale > 0 else { return }
                model.beginDrag(.move)
                model.dragMove(by: value.translation.width / scale)
            }
            .onEnded { _ in model.endDrag() }
    }

    private func resizeGesture(scale: Double, isLeading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.timelineSpace))
            .onChanged { value in
                guard scale > 0 else { return }
                let delta = value.translation.width / scale
                if isLeading {
                    model.beginDrag(.leading)
                    model.dragLeading(by: delta)
                } else {
                    model.beginDrag(.trailing)
                    model.dragTrailing(by: delta)
                }
            }
            .onEnded { _ in model.endDrag() }
    }

    // MARK: 控件与提示

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(model.availablePresets, id: \.self) { preset in
                presetButton(preset)
            }
            Spacer()
            Toggle("精确裁剪", isOn: $model.preciseTrim)
                .toggleStyle(.checkbox)
                .help("关闭吸附，从任意帧切开。代价是视频轨要重新编码，画质会有损失。")
        }
    }

    /// 选中的预设用实心蓝按钮。`.bordered` 只改 tint 在 macOS 上视觉差异太弱，
    /// 用户会以为点了没反应。
    @ViewBuilder
    private func presetButton(_ preset: Double) -> some View {
        let title = preset == 1.5 ? "1.5s" : "\(Int(preset))s"
        if model.isPresetActive(preset) {
            Button(title) { model.applyPreset(preset) }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
        } else {
            Button(title) { model.applyPreset(preset) }
                .buttonStyle(.bordered)
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.inputError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let hint = model.rangeHint {
                Label(hint, systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.preciseTrim {
                Label("已关闭关键帧吸附，视频轨将被重新编码，画质有损。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.showsLengthWarning {
                Label("超过 10 秒了。部分平台（微信朋友圈、小红书）只认 3 秒以内的实况。",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
