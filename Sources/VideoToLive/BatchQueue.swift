import CoreMedia
import Foundation
import VideoToLiveCore

/// 队列里的一项。区间在入队时就定下来，之后不再改。
struct QueueItem: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case running(stage: LivePhotoStage, progress: Double)
        case succeeded(summary: String, localIdentifier: String?)
        case failed(message: String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .succeeded, .failed, .cancelled: return true
            case .waiting, .running: return false
            }
        }
    }

    let id = UUID()
    let url: URL
    let start: Double
    let duration: Double
    let preciseTrim: Bool
    var status: Status = .waiting

    var name: String { url.lastPathComponent }
}

/// 批量队列（方案 4.5）：逐个显示状态，封面统一自动挑选，可暂停、可取消。
@MainActor
final class BatchQueue: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    /// 暂停只是不再开新任务，已经在跑的会做完。
    @Published private(set) var isPaused = false

    /// 同时最多跑几个。4K 素材每个要占几百 MB，再多内存就吃不消了。
    static let maxConcurrent = 2
    /// 一次拖入多个文件时的默认区间：从头取 3 秒，视频不足 3 秒就取整段。
    static let defaultDuration: Double = 3

    private let history: HistoryStore
    private var tasks: [QueueItem.ID: Task<Void, Never>] = [:]

    init(history: HistoryStore) {
        self.history = history
    }

    var runningCount: Int { tasks.count }
    var waitingCount: Int { items.filter { $0.status == .waiting }.count }
    var finishedCount: Int { items.filter { $0.status.isFinished }.count }
    var hasUnfinished: Bool { items.contains { !$0.status.isFinished } }

    // MARK: - 入队

    func add(urls: [URL]) {
        for url in urls {
            items.append(QueueItem(url: url, start: 0, duration: Self.defaultDuration, preciseTrim: false))
        }
        schedule()
    }

    func add(url: URL, start: Double, duration: Double, preciseTrim: Bool) {
        items.append(QueueItem(url: url, start: start, duration: duration, preciseTrim: preciseTrim))
        schedule()
    }

    // MARK: - 控制

    func pause() { isPaused = true }

    func resume() {
        isPaused = false
        schedule()
    }

    func cancel(_ id: QueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .waiting:
            items[index].status = .cancelled
        case .running:
            // 状态由任务收尾时改写，这里只发信号。
            tasks[id]?.cancel()
        default:
            break
        }
    }

    func cancelAll() {
        for item in items where !item.status.isFinished { cancel(item.id) }
    }

    func retry(_ id: QueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].status.isFinished else { return }
        items[index].status = .waiting
        schedule()
    }

    func remove(_ id: QueueItem.ID) {
        guard let item = items.first(where: { $0.id == id }), item.status.isFinished else { return }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    func revealInPhotos(_ item: QueueItem) {
        guard case .succeeded(_, let identifier?) = item.status else { return }
        PhotoLibraryImporter.revealInPhotos(localIdentifier: identifier)
    }

    // MARK: - 调度

    /// 有空位就从前往后取等待中的项开跑。每次状态变化后都调一次。
    private func schedule() {
        guard !isPaused else { return }
        while tasks.count < Self.maxConcurrent,
              let next = items.first(where: { $0.status == .waiting }) {
            start(next)
        }
    }

    private func start(_ item: QueueItem) {
        update(item.id) { $0.status = .running(stage: .inspect, progress: 0) }

        let request = ConversionRequest(
            sourceURL: item.url,
            start: CMTime(seconds: item.start, preferredTimescale: 600),
            duration: CMTime(seconds: item.duration, preferredTimescale: 600),
            cover: .automatic(sampleCount: 24),
            coverFormat: .heic,
            coverQuality: 1.0,
            keepAudio: true,
            preciseTrim: item.preciseTrim,
            importToLibrary: true
        )
        let id = item.id

        tasks[id] = Task {
            do {
                let result = try await LivePhotoConverter.convert(request) { stage, fraction in
                    Task { @MainActor in
                        self.update(id) { item in
                            // 收尾后晚到的进度回调不能把状态改回「处理中」。
                            guard case .running = item.status else { return }
                            item.status = .running(stage: stage, progress: fraction)
                        }
                    }
                }
                self.history.append(HistoryRecord(origin: .batch, request: request, result: result))
                self.update(id) {
                    $0.status = .succeeded(summary: Self.summary(of: result),
                                           localIdentifier: result.importResult?.localIdentifier)
                }
            } catch {
                self.history.append(HistoryRecord(origin: .batch, request: request, error: error))
                self.update(id) {
                    $0.status = error is CancellationError
                        ? .cancelled : .failed(message: Self.message(for: error))
                }
            }
            self.tasks[id] = nil
            self.schedule()
        }
    }

    private func update(_ id: QueueItem.ID, _ change: (inout QueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private static func summary(of result: ConversionResult) -> String {
        let mode = result.remux.didPassthrough ? "无损" : "重编码"
        return String(format: "%@ – %@ · %.1f MB · %@",
                      Timecode.format(result.remux.actualStart.seconds),
                      Timecode.format(result.remux.actualEnd.seconds),
                      Double(result.totalSize) / 1_048_576, mode)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LivePhotoError {
            return "\(error.stage.rawValue)：\(error.reason)"
        }
        return error.localizedDescription
    }
}
