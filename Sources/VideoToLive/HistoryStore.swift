import AppKit
import Foundation
import VideoToLiveCore

/// 一次转换的记录。成功和失败都记，失败时要能说清卡在哪一步。
struct HistoryRecord: Codable, Identifiable, Equatable {
    enum Origin: String, Codable { case single, batch }
    enum Outcome: String, Codable { case succeeded, failed, cancelled }

    var id = UUID()
    var date: Date
    var origin: Origin
    var outcome: Outcome

    var sourcePath: String
    var requestedStart: Double
    var requestedDuration: Double
    var preciseTrim: Bool

    // 成功时才有
    var actualStart: Double?
    var actualEnd: Double?
    /// "无损直通" / "重编码"
    var modeLabel: String?
    var totalSize: Int64?
    var coverTime: Double?
    var coverSharpness: Double?
    var localIdentifier: String?
    var isLivePhoto: Bool?

    // 失败时才有
    var failedStage: String?
    var failureReason: String?
    var failureDetail: String?

    var sourceName: String { (sourcePath as NSString).lastPathComponent }
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
}

extension HistoryRecord {
    init(origin: Origin, request: ConversionRequest, result: ConversionResult) {
        self.date = Date()
        self.origin = origin
        self.outcome = .succeeded
        self.sourcePath = request.sourceURL.path
        self.requestedStart = request.start.seconds
        self.requestedDuration = request.duration.seconds
        self.preciseTrim = request.preciseTrim
        self.actualStart = result.remux.actualStart.seconds
        self.actualEnd = result.remux.actualEnd.seconds
        self.modeLabel = result.remux.didPassthrough ? "无损直通" : "重编码"
        self.totalSize = result.totalSize
        self.coverTime = result.coverTime.seconds
        self.coverSharpness = result.coverSharpness
        self.localIdentifier = result.importResult?.localIdentifier
        self.isLivePhoto = result.importResult?.isLivePhoto
    }

    init(origin: Origin, request: ConversionRequest, error: Error) {
        self.date = Date()
        self.origin = origin
        self.sourcePath = request.sourceURL.path
        self.requestedStart = request.start.seconds
        self.requestedDuration = request.duration.seconds
        self.preciseTrim = request.preciseTrim
        if error is CancellationError {
            self.outcome = .cancelled
        } else if let error = error as? LivePhotoError {
            self.outcome = .failed
            self.failedStage = error.stage.rawValue
            self.failureReason = error.reason
            self.failureDetail = error.underlying?.localizedDescription
        } else {
            self.outcome = .failed
            self.failureReason = error.localizedDescription
        }
    }
}

/// 历史记录，存在 Application Support 下的一个 JSON 文件里，新的在前。
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []
    /// 列表里展开详情的那一条。放在这里而不是视图里：@State 用不了。
    @Published var expandedID: HistoryRecord.ID?
    @Published var isConfirmingClear = false

    /// 只留最近这么多条，免得文件无限变大。
    static let limit = 500

    private let fileURL: URL

    init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoToLive", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    func append(_ record: HistoryRecord) {
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    func remove(_ id: HistoryRecord.ID) {
        records.removeAll { $0.id == id }
        if expandedID == id { expandedID = nil }
        save()
    }

    func clear() {
        records = []
        expandedID = nil
        save()
    }

    func toggleExpanded(_ id: HistoryRecord.ID) {
        expandedID = expandedID == id ? nil : id
    }

    func revealSource(_ record: HistoryRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.sourceURL])
    }

    func revealInPhotos(_ record: HistoryRecord) {
        guard let identifier = record.localIdentifier else { return }
        PhotoLibraryImporter.revealInPhotos(localIdentifier: identifier)
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try Self.decoder.decode([HistoryRecord].self, from: data)
        } catch {
            // 文件坏了不能让 App 起不来。挪到一边留着排查，从空记录开始。
            let broken = fileURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: fileURL, to: broken)
            records = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("VideoToLive: 历史记录写盘失败 %@", error.localizedDescription)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
