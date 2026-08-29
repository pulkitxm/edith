import EdithCore
import Foundation

public struct AutomationStorage: Sendable {
    public let documentURL: URL
    public let historyURL: URL
    public let historyLimit: Int
    public let historyMaxAge: TimeInterval
    private let settingsBackupEnabled: Bool

    public init(
        root: URL = AppDirectories.current.data, historyLimit: Int = 200,
        historyMaxAge: TimeInterval = 60 * 60 * 24 * 30
    ) {
        documentURL = root.appendingPathComponent("automations.json")
        historyURL = root.appendingPathComponent("automation-history.json")
        self.historyLimit = max(1, historyLimit)
        self.historyMaxAge = max(60, historyMaxAge)
        settingsBackupEnabled =
            root.standardizedFileURL == AppDirectories.current.data.standardizedFileURL
    }

    public func load() throws -> AutomationDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            if settingsBackupEnabled,
                let data = SharedDefaults.store.data(
                    forKey: AppStorageKeys.Automations.documentBackup)
            {
                let document = try decoder.decode(AutomationDocument.self, from: data)
                guard document.version == 1 else {
                    throw AutomationStorageError.unsupportedVersion(document.version)
                }
                return document
            }
            return AutomationDocument()
        }
        let document = try decoder.decode(
            AutomationDocument.self, from: Data(contentsOf: documentURL))
        guard document.version == 1 else {
            throw AutomationStorageError.unsupportedVersion(document.version)
        }
        return document
    }

    public func save(_ document: AutomationDocument) throws {
        guard document.version == 1 else {
            throw AutomationStorageError.unsupportedVersion(document.version)
        }
        try prepare(documentURL)
        let data = try encoder.encode(document)
        try data.write(to: documentURL, options: .atomic)
        if settingsBackupEnabled {
            SharedDefaults.store.set(data, forKey: AppStorageKeys.Automations.documentBackup)
        }
    }

    public func export(to url: URL) throws {
        let document = try load()
        try prepare(url)
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    public func importDocument(from url: URL, dryRun: Bool = false) throws -> AutomationDocument {
        let document = try decoder.decode(AutomationDocument.self, from: Data(contentsOf: url))
        guard document.version == 1 else {
            throw AutomationStorageError.unsupportedVersion(document.version)
        }
        if !dryRun { try save(document) }
        return document
    }

    public func history(now: Date = Date()) throws -> [AutomationRunRecord] {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        let records = try decoder.decode(
            [AutomationRunRecord].self, from: Data(contentsOf: historyURL))
        return bounded(records, now: now)
    }

    public func append(_ record: AutomationRunRecord, now: Date = Date()) throws {
        let records = bounded(((try? history(now: now)) ?? []) + [record], now: now)
        try prepare(historyURL)
        try encoder.encode(records).write(to: historyURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.prettyPrinted, .sortedKeys]
        return value
    }

    private var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private func prepare(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private func bounded(_ records: [AutomationRunRecord], now: Date) -> [AutomationRunRecord] {
        let cutoff = now.addingTimeInterval(-historyMaxAge)
        return Array(records.filter { $0.startedAt >= cutoff }.suffix(historyLimit))
    }
}

public enum AutomationStorageError: LocalizedError, Equatable {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported automations version \(version)."
        }
    }
}
