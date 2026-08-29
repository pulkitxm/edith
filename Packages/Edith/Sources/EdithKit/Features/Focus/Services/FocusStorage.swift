import EdithCore
import Foundation

public struct FocusStorage: Sendable {
    public let documentURL: URL
    public let sessionURL: URL
    public let historyURL: URL
    public let historyLimit: Int
    public let historyMaxAge: TimeInterval
    private let settingsBackupEnabled: Bool

    public init(
        root: URL = AppDirectories.current.data, historyLimit: Int = 200,
        historyMaxAge: TimeInterval = 60 * 60 * 24 * 30
    ) {
        documentURL = root.appendingPathComponent("focus-profiles.json")
        sessionURL = root.appendingPathComponent("focus-session.json")
        historyURL = root.appendingPathComponent("focus-history.json")
        self.historyLimit = max(1, historyLimit)
        self.historyMaxAge = max(60, historyMaxAge)
        settingsBackupEnabled =
            root.standardizedFileURL == AppDirectories.current.data.standardizedFileURL
    }

    public func load() throws -> FocusDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            if settingsBackupEnabled,
                let data = SharedDefaults.store.data(forKey: AppStorageKeys.Focus.documentBackup)
            {
                return try decodeDocument(data)
            }
            return FocusDocument()
        }
        return try decodeDocument(Data(contentsOf: documentURL))
    }

    public func save(_ document: FocusDocument) throws {
        guard document.version == 1 else {
            throw FocusStorageError.unsupportedVersion(document.version)
        }
        let data = try encoder.encode(document)
        try write(data, to: documentURL)
        if settingsBackupEnabled {
            SharedDefaults.store.set(data, forKey: AppStorageKeys.Focus.documentBackup)
        }
    }

    public func session() throws -> FocusSession? {
        guard FileManager.default.fileExists(atPath: sessionURL.path) else { return nil }
        return try decoder.decode(FocusSession.self, from: Data(contentsOf: sessionURL))
    }

    public func saveSession(_ session: FocusSession?) throws {
        guard let session else {
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                try FileManager.default.removeItem(at: sessionURL)
            }
            return
        }
        try write(encoder.encode(session), to: sessionURL)
    }

    public func history(now: Date = Date()) throws -> [FocusHistoryRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let records = try decoder.decode(
            [FocusHistoryRecord].self, from: Data(contentsOf: historyURL))
        return bounded(records, now: now)
    }

    public func append(_ record: FocusHistoryRecord, now: Date = Date()) throws {
        let records = bounded(((try? history(now: now)) ?? []) + [record], now: now)
        try write(encoder.encode(records), to: historyURL)
    }

    private func decodeDocument(_ data: Data) throws -> FocusDocument {
        let document = try decoder.decode(FocusDocument.self, from: data)
        guard document.version == 1 else {
            throw FocusStorageError.unsupportedVersion(document.version)
        }
        return document
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func bounded(_ records: [FocusHistoryRecord], now: Date) -> [FocusHistoryRecord] {
        let cutoff = now.addingTimeInterval(-historyMaxAge)
        return Array(records.filter { $0.endedAt >= cutoff }.suffix(historyLimit))
    }
}

public enum FocusStorageError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported focus profiles version \(version)."
        }
    }
}
