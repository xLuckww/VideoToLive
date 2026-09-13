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
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if model.isPickingCover {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 62)
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
                selectionBox(startX: startX, width: selectionWidth, scale: scale)
            }
            .frame(width: width, height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
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

    private func moveGesture(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard scale > 0 else { return }
                let origin = model.dragOriginStart ?? model.selectionStart
                model.dragOriginStart = origin
                model.setStart(origin + value.translation.width / scale)
            }
            .onEnded { _ in
                model.dragOriginStart = nil
                model.scheduleCoverPreview()
            }
    }

    private func resizeGesture(scale: Double, isLeading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard scale > 0 else { return }
                let originStart = model.dragOriginStart ?? model.selectionStart
                let originDuration = model.dragOriginDuration ?? model.selectionDuration
                model.dragOriginStart = originStart
                model.dragOriginDuration = originDuration
                let delta = value.translation.width / scale
                if isLeading {
                    // 左把手：终点钉住，起点动
                    let end = originStart + originDuration
                    model.setStart(min(max(0, originStart + delta), end - 0.2))
                    model.setDuration(end - model.selectionStart)
                } else {
                    model.setDuration(originDuration + delta)
                }
            }
            .onEnded { _ in
                model.dragOriginStart = nil
                model.dragOriginDuration = nil
                model.scheduleCoverPreview()
            }
    }

    // MARK: 控件与提示

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(model.availablePresets, id: \.self) { preset in
                let active = model.isPresetActive(preset)
                Button(preset == 1.5 ? "1.5s" : "\(Int(preset))s") {
                    model.applyPreset(preset)
                }
                .buttonStyle(.bordered)
                .tint(active ? .accentColor : nil)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
            }
            Spacer()
            Toggle("精确裁剪", isOn: $model.preciseTrim)
                .toggleStyle(.checkbox)
                .help("关闭吸附，从任意帧切开。代价是视频轨要重新编码，画质会有损失。")
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
