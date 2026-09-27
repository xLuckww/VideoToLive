import SwiftUI
import VideoToLiveCore

/// 左侧面板：批量队列与历史记录，可收起。顶部 52pt 留给红绿灯和拖动窗口。
struct SidePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: BatchQueue
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea().frame(height: 52)
            SegmentedChoice(
                options: [AppModel.SidePanelTab.queue, .history],
                label: { tab in
                    switch tab {
                    case .queue:
                        let pending = queue.items.filter { !$0.status.isFinished }.count
                        return pending > 0 ? "队列 \(pending)" : "队列"
                    case .history:
                        return "历史"
                    }
                },
                isSelected: { $0 == model.sidePanelTab },
                onSelect: { model.sidePanelTab = $0 }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)

            switch model.sidePanelTab {
            case .queue:   QueueList(queue: queue)
            case .history: HistoryList(model: model, history: history)
            }
        }
        .background(Theme.panel)
    }
}

/// 收起 / 展开左侧面板的按钮，放在顶栏最左边。
struct SidePanelToggle: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.showsSidePanel.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 13))
        }
        .buttonStyle(GhostButtonStyle())
        .help(model.showsSidePanel ? "收起队列与历史" : "展开队列与历史")
    }
}

// MARK: - 队列

struct QueueList: View {
    @ObservedObject var queue: BatchQueue

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if queue.items.isEmpty {
                placeholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.items) { item in
                            QueueRow(item: item, queue: queue)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if queue.hasUnfinished {
                Button(queue.isPaused ? "继续" : "暂停") {
                    queue.isPaused ? queue.resume() : queue.pause()
                }
                .buttonStyle(GhostButtonStyle())
                .help(queue.isPaused ? "继续处理等待中的视频" : "不再开始新的，正在处理的会做完")
                Button("全部取消") { queue.cancelAll() }
                    .buttonStyle(GhostButtonStyle())
            }
            if queue.finishedCount > 0 {
                Button("清除已完成") { queue.clearFinished() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var statusText: String {
        if queue.items.isEmpty { return "空闲" }
        var parts: [String] = []
        if queue.runningCount > 0 { parts.append("处理中 \(queue.runningCount)") }
        if queue.waitingCount > 0 { parts.append("等待 \(queue.waitingCount)") }
        if queue.isPaused { parts.append("已暂停") }
        return parts.isEmpty ? "全部完成" : parts.joined(separator: " · ")
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text("一次拖入多个视频，会按「从头取 3 秒」排队处理。\n单个视频可以在编辑器里调好区间后点「加入队列」。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QueueRow: View {
    let item: QueueItem
    @ObservedObject var queue: BatchQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                actions
            }
            Text(rangeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            statusDetail
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 0.5))
    }

    private var rangeText: String {
        var text = String(format: "%@ 起 · %.2f s", Timecode.format(item.start), item.duration)
        if item.preciseTrim { text += " · 精确裁剪" }
        return text
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(Theme.textMuted)
        case .running:
            ProgressView().controlSize(.mini).tint(Theme.accent)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder private var statusDetail: some View {
        switch item.status {
        case .waiting:
            detailText(queue.isPaused ? "等待中（队列已暂停）" : "等待中", color: Theme.textMuted)
        case .running(let stage, let progress):
            VStack(alignment: .leading, spacing: 4) {
                detailText("正在\(stage.rawValue)…", color: Theme.accentText)
                // 只有封装阶段有真实进度，其余阶段给个满格前的占位。
                ProgressView(value: stage == .remux ? progress : stageFloor(stage))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }
        case .succeeded(let summary, _):
            detailText(summary, color: Theme.textSecondary)
        case .failed(let message):
            detailText(message, color: Theme.danger)
                .textSelection(.enabled)
        case .cancelled:
            detailText("已取消", color: Theme.textMuted)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.status {
        case .waiting, .running:
            iconButton("xmark", help: "取消") { queue.cancel(item.id) }
        case .succeeded:
            Button("在照片中显示") { queue.revealInPhotos(item) }
                .buttonStyle(GhostButtonStyle())
            iconButton("xmark", help: "从列表移除") { queue.remove(item.id) }
        case .failed, .cancelled:
            Button("重试") { queue.retry(item.id) }
                .buttonStyle(GhostButtonStyle())
            iconButton("xmark", help: "从列表移除") { queue.remove(item.id) }
        }
    }

    private func detailText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(GhostButtonStyle())
        .help(help)
    }

    /// 进度条的大致位置：按阶段顺序给个固定比例，封装阶段再按真实进度走。
    private func stageFloor(_ stage: LivePhotoStage) -> Double {
        switch stage {
        case .inspect:       return 0.02
        case .extractCover:  return 0.1
        case .encodeCover:   return 0.2
        case .remux:         return 0.3
        case .importLibrary: return 1
        }
    }
}

// MARK: - 历史

struct HistoryList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(history.records.isEmpty ? "暂无记录" : "共 \(history.records.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if !history.records.isEmpty {
                    Button("清空") { history.isConfirmingClear = true }
                        .buttonStyle(GhostButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)

            if history.records.isEmpty {
                Text("转换过的视频会记在这里，\n成功和失败都会记。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history.records) { record in
                            HistoryRow(record: record, model: model, history: history)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .confirmationDialog("清空全部历史记录？", isPresented: $history.isConfirmingClear) {
            Button("清空", role: .destructive) { history.clear() }
        } message: {
            Text("只删除记录，不影响照片图库里已经写入的实况。")
        }
    }
}

struct HistoryRow: View {
    let record: HistoryRecord
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore

    private var isExpanded: Bool { history.expandedID == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { history.toggleExpanded(record.id) } label: { summary }
                .buttonStyle(.plain)
            if isExpanded {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                details
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .strokeBorder(isExpanded ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 0.5))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                outcomeIcon
                Text(record.sourceName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: 6) {
                Text(Self.dateFormatter.string(from: record.date))
                Text("·")
                Text(outcomeLine).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(record.outcome == .failed ? Theme.danger : Theme.textSecondary)
        }
        .contentShape(Rectangle())
    }

    private var outcomeLine: String {
        switch record.outcome {
        case .succeeded:
            var parts: [String] = []
            if let size = record.totalSize { parts.append(String(format: "%.1f MB", Double(size) / 1_048_576)) }
            if let mode = record.modeLabel { parts.append(mode) }
            return parts.joined(separator: " · ")
        case .failed:
            return "失败" + (record.failedStage.map { "于「\($0)」" } ?? "")
        case .cancelled:
            return "已取消"
        }
    }

    @ViewBuilder private var outcomeIcon: some View {
        switch record.outcome {
        case .succeeded:
            Image(systemName: record.isLivePhoto == false ? "exclamationmark.circle" : "livephoto")
                .foregroundStyle(record.isLivePhoto == false ? Theme.warning : Theme.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(Theme.textMuted)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            detail("来源", record.origin == .batch ? "批量队列" : "单个转换")
            detail("请求区间", String(format: "%@ 起 · %.2f s%@",
                                    Timecode.format(record.requestedStart), record.requestedDuration,
                                    record.preciseTrim ? " · 精确裁剪" : ""))
            if let start = record.actualStart, let end = record.actualEnd {
                detail("实际区间", "\(Timecode.format(start)) – \(Timecode.format(end))")
            }
            if let cover = record.coverTime {
                detail("封面帧", Timecode.format(cover)
                       + (record.coverSharpness.map { String(format: " · 清晰度 %.0f", $0) } ?? ""))
            }
            if let isLive = record.isLivePhoto {
                detail("识别为实况", isLive ? "是" : "否")
            }
            if let reason = record.failureReason {
                detail("失败原因", reason, color: Theme.danger)
            }
            if let underlying = record.failureDetail {
                detail("底层错误", underlying)
            }
            detail("源文件", record.sourcePath)

            HStack(spacing: 2) {
                if record.localIdentifier != nil {
                    Button("在照片中显示") { history.revealInPhotos(record) }
                        .buttonStyle(GhostButtonStyle())
                }
                if sourceExists {
                    Button("在访达中显示") { history.revealSource(record) }
                        .buttonStyle(GhostButtonStyle())
                    Button("重新编辑") { model.load(record.sourceURL) }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(model.phase == .converting)
                }
                Spacer(minLength: 0)
                Button("删除") { history.remove(record.id) }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(.top, 2)
        }
    }

    private var sourceExists: Bool {
        FileManager.default.fileExists(atPath: record.sourcePath)
    }

    private func detail(_ label: String, _ value: String, color: Color = Theme.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
