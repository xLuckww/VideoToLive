import VideoToLiveCore
import SwiftUI

/// 底部时间轴区：播放与关键帧步进、起止时间、刻度尺、缩略图条与选区、提示。
struct TimelineDock: View {
    @ObservedObject var model: AppModel

    private let stripHeight: CGFloat = 56
    private let rulerHeight: CGFloat = 18
    private let handleWidth: CGFloat = 10

    /// 手势坐标必须以整条时间轴为参照。选区框自己会跟着拖动移动，
    /// 若用默认的 .local，框一动手势位移就被抵消一截，框又被拉回——来回晃动。
    private static let timelineSpace = "timeline"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            transportRow
            VStack(spacing: 4) {
                ruler
                filmstrip
            }
            notices
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Theme.dock)
    }

    // MARK: 播放与起止时间

    private var transportRow: some View {
        HStack(spacing: 8) {
            Button { model.togglePlaySelection() } label: {
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
            }
            .buttonStyle(RoundIconButtonStyle(prominent: true))
            .help(model.isPlaying ? "停止" : "播放选段")
            .disabled(model.player == nil)

            if model.canStepKeyframes {
                Button { model.stepToPreviousKeyframe() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(RoundIconButtonStyle())
                .help("起点跳到上一关键帧")
                .disabled(model.previousKeyframe == nil)

                Button { model.stepToNextKeyframe() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(RoundIconButtonStyle())
                .help("起点跳到下一关键帧")
                .disabled(model.nextKeyframe == nil)
            }

            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 18).padding(.horizontal, 6)

            TimecodeField(label: "起点", text: $model.startInput) { model.previewStartInput() }
            TimecodeField(label: "终点", text: $model.endInput) { model.previewEndInput() }

            Spacer(minLength: 12)

            ThemedCheckbox(title: "精确裁剪", isOn: model.preciseTrim) {
                model.preciseTrim.toggle()
            }
            .help("关闭关键帧吸附，从任意帧切开。代价是视频轨要重新编码，画质会有损失。")
        }
    }

    // MARK: 刻度尺

    /// 顶部刻度：时间标签 + 关键帧短竖线。竖线放在尺上而不是缩略图上，浅色主题下才看得清。
    private var ruler: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = model.maxDuration > 0 ? width / model.maxDuration : 0
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.keyframes.enumerated()), id: \.offset) { _, time in
                    Rectangle()
                        .fill(Theme.textMuted.opacity(0.5))
                        .frame(width: 1, height: 4)
                        .offset(x: time * scale, y: rulerHeight - 4)
                }
                ForEach(0..<5, id: \.self) { index in
                    let ratio = Double(index) / 4
                    Text(shortTime(model.maxDuration * ratio))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize()
                        .frame(width: 44, alignment: index == 0 ? .leading : (index == 4 ? .trailing : .center))
                        .offset(x: labelOffset(ratio: ratio, width: width, labelWidth: 44))
                }
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 1.5, height: 6)
                    .offset(x: model.playheadTime * scale, y: rulerHeight - 6)
            }
        }
        .frame(height: rulerHeight)
    }

    private func labelOffset(ratio: Double, width: Double, labelWidth: Double) -> Double {
        if ratio == 0 { return 0 }
        if ratio == 1 { return width - labelWidth }
        return width * ratio - labelWidth / 2
    }

    private func shortTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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

                // 选区外用窗口底色蒙一层，浅色主题下比压黑更清爽
                Theme.window.opacity(0.68)
                    .frame(width: max(0, startX), height: stripHeight)
                Theme.window.opacity(0.68)
                    .frame(width: max(0, width - startX - selectionWidth), height: stripHeight)
                    .offset(x: startX + selectionWidth)

                playhead(scale: scale)
                selectionBox(startX: startX, width: selectionWidth, scale: scale)
            }
            .frame(width: width, height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.timelineSpace)
        }
        .frame(height: stripHeight)
    }

    private var thumbnailRow: some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Rectangle().fill(Theme.canvas)
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

    /// 播放头。播放时随画面移动，停着时停在预览窗当前那一帧。
    private func playhead(scale: Double) -> some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 2, height: stripHeight)
            .offset(x: model.playheadTime * scale)
            .opacity(model.isPlaying ? 1 : 0.55)
    }

    private func selectionBox(startX: Double, width selectionWidth: Double, scale: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: selectionWidth, height: stripHeight)
                .contentShape(Rectangle())
                .gesture(moveGesture(scale: scale))

            handle(at: 0, scale: scale, isLeading: true)
            handle(at: selectionWidth - handleWidth, scale: scale, isLeading: false)
        }
        .offset(x: startX)
    }

    private func handle(at offset: Double, scale: Double, isLeading: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isLeading ? 6 : 0,
            bottomLeadingRadius: isLeading ? 6 : 0,
            bottomTrailingRadius: isLeading ? 0 : 6,
            topTrailingRadius: isLeading ? 0 : 6
        )
        .fill(Theme.accent)
        .frame(width: handleWidth, height: stripHeight)
        .overlay(Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: 16))
        .offset(x: offset)
        .contentShape(Rectangle())
        .gesture(resizeGesture(scale: scale, isLeading: isLeading))
    }

    // MARK: 手势（拖动中跟手，松手时吸附）

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

    // MARK: 提示

    /// 所有提示集中在这一行，统一用琥珀色，不再散落在各处。
    private var notices: some View {
        let messages: [String] = [
            model.inputError,
            model.rangeHint,
            model.preciseTrim ? "已关闭关键帧吸附，视频轨将被重新编码，画质有损" : nil,
            model.showsLengthWarning ? "超过 10 秒，部分平台只认 3 秒以内的实况" : nil,
        ].compactMap { $0 }

        return HStack(spacing: 6) {
            if !messages.isEmpty {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                Text(messages.joined(separator: " · "))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(Theme.warning)
        .frame(height: 14, alignment: .leading)
    }
}
