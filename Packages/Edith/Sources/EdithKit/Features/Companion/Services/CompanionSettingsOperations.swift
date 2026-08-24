import EdithCore
import Foundation

public enum CompanionSettingsOperation: String, CaseIterable, Identifiable, Sendable {
    case syncGithub
    case exportData
    case importData
    case wipe
    case dbReindex
    case dbRebuildDerived
    case connectorsSet
    case connectorsImport
    case reasonSet
    case reasonTest

    public var id: String { rawValue }

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: operationID), summary: summary, cli: cli,
            effect: effect, requiresPreview: requiresPreview)
    }

    public var uiPlacement: String {
        switch self {
        case .syncGithub: "Companion settings > Connectors > Sync GitHub"
        case .exportData: "Companion settings > Your data > Export"
        case .importData: "Companion settings > Your data > Import"
        case .wipe: "Companion settings > Danger zone > Wipe"
        case .dbReindex: "Companion settings > Danger zone > Reindex"
        case .dbRebuildDerived: "Companion settings > Danger zone > Rebuild"
        case .connectorsSet: "Companion settings > Connectors > Save tokens"
        case .connectorsImport: "Companion settings > Connectors > Import an export"
        case .reasonSet: "Companion settings > Reasoner > Save"
        case .reasonTest: "Companion settings > Reasoner > Test connection"
        }
    }

    public var previewTargets: [String] {
        switch self {
        case .wipe:
            ["all companion memory records", "all companion vault files"]
        case .dbReindex:
            ["search chunks for every episode"]
        case .dbRebuildDerived:
            ["search chunks", "active beliefs", "open facts"]
        default:
            []
        }
    }

    private var operationID: String {
        switch self {
        case .syncGithub: "companion.connector.github.sync"
        case .exportData: "companion.data.export"
        case .importData: "companion.data.import"
        case .wipe: "companion.data.wipe"
        case .dbReindex: "companion.database.reindex"
        case .dbRebuildDerived: "companion.database.rebuild-derived"
        case .connectorsSet: "companion.connector.set"
        case .connectorsImport: "companion.connector.import"
        case .reasonSet: "companion.reason.set"
        case .reasonTest: "companion.reason.test"
        }
    }

    private var cli: [String] {
        switch self {
        case .syncGithub: ["companion", "sync"]
        case .exportData: ["companion", "export"]
        case .importData: ["companion", "import"]
        case .wipe: ["companion", "wipe"]
        case .dbReindex: ["companion", "db", "reindex"]
        case .dbRebuildDerived: ["companion", "db", "rebuild-derived"]
        case .connectorsSet: ["companion", "connectors", "set"]
        case .connectorsImport: ["companion", "connectors", "import"]
        case .reasonSet: ["companion", "reason", "set"]
        case .reasonTest: ["companion", "reason", "test"]
        }
    }

    private var summary: String {
        switch self {
        case .syncGithub: "Pull GitHub activity into observations."
        case .exportData: "Export companion memory as a restorable bundle."
        case .importData: "Restore a companion memory bundle."
        case .wipe: "Delete all companion memory and vault files."
        case .dbReindex: "Rebuild every episode's search chunks."
        case .dbRebuildDerived: "Discard and rebuild all derived memory."
        case .connectorsSet: "Store or clear connector tokens."
        case .connectorsImport: "Import connector observations from a file."
        case .reasonSet: "Change the active reasoning configuration."
        case .reasonTest: "Test the active reasoning configuration."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .exportData, .reasonTest: .read
        case .wipe, .dbReindex, .dbRebuildDerived: .destructive
        case .syncGithub, .importData, .connectorsSet, .connectorsImport, .reasonSet: .write
        }
    }

    private var requiresPreview: Bool {
        switch self {
        case .wipe, .dbReindex, .dbRebuildDerived: true
        default: false
        }
    }
}

public enum CompanionSettingsOperationError: LocalizedError, Equatable, Sendable {
    case noConnectorTokens
    case unsupportedConnector(String)
    case unreadableFile(String, String)
    case noReasonChanges
    case unsupportedReasonProvider(String)

    public var errorDescription: String? {
        switch self {
        case .noConnectorTokens:
            "Pass at least one connector token to store or clear."
        case .unsupportedConnector(let source):
            "The import source \(source) is not supported."
        case .unreadableFile(let path, let detail):
            "Could not read \(path): \(detail)"
        case .noReasonChanges:
            "Pass at least one reasoning setting to change."
        case .unsupportedReasonProvider(let provider):
            "The reasoning provider \(provider) is not supported."
        }
    }
}

public struct CompanionConnectorTokenUpdate: Equatable, Sendable {
    public let github: String?
    public let notion: String?

    public init(github: String?, notion: String?) throws {
        guard github != nil || notion != nil else {
            throw CompanionSettingsOperationError.noConnectorTokens
        }
        self.github = github
        self.notion = notion
    }
}

public struct CompanionReasonConfigurationUpdate: Equatable, Sendable {
    public let provider: String?
    public let url: String?
    public let model: String?
    public let apiKey: String?

    public init(provider: String?, url: String?, model: String?, apiKey: String?) throws {
        if let provider, !["anthropic", "openai", ""].contains(provider) {
            throw CompanionSettingsOperationError.unsupportedReasonProvider(provider)
        }
        guard provider != nil || url != nil || model != nil || apiKey != nil else {
            throw CompanionSettingsOperationError.noReasonChanges
        }
        self.provider = provider
        self.url = url
        self.model = model
        self.apiKey = apiKey
    }
}

public struct CompanionReindexResult: Sendable {
    public let maintenance: CompanionRebuildOutcome
    public let indexing: CompanionIndexOutcome

    public init(maintenance: CompanionRebuildOutcome, indexing: CompanionIndexOutcome) {
        self.maintenance = maintenance
        self.indexing = indexing
    }
}

public struct CompanionSettingsOperationExecution: Sendable {
    public static let importableConnectorSources = ["calendar", "music", "youtube"]

    public let client: CompanionClient

    public init(client: CompanionClient) {
        self.client = client
    }

    public func syncGithub() async throws -> CompanionSyncOutcome {
        try await client.syncGithub()
    }

    public func exportData(
        into directory: URL, includeMedia: Bool
    ) async throws -> CompanionExportResult {
        try await CompanionDataTransfer.export(
            client: client, into: directory, includeMedia: includeMedia)
    }

    public func importData(from path: URL) async throws -> CompanionImportResult {
        try await CompanionDataTransfer.restore(client: client, from: path)
    }

    public func wipe() async throws -> CompanionWipeOutcome {
        try await client.wipe(confirm: "everything")
    }

    public func reindex() async throws -> CompanionReindexResult {
        let maintenance = try await client.db("reindex")
        let indexing = try await client.index()
        return CompanionReindexResult(maintenance: maintenance, indexing: indexing)
    }

    public func rebuildDerived() async throws -> CompanionRebuildOutcome {
        try await client.db("rebuild-derived")
    }

    public func updateConnectors(
        _ update: CompanionConnectorTokenUpdate
    ) async throws -> CompanionConnectorSettings {
        try await client.updateConnectorSettings(github: update.github, notion: update.notion)
    }

    public func importConnector(source: String, from url: URL) async throws
        -> CompanionImportOutcome
    {
        guard Self.importableConnectorSources.contains(source) else {
            throw CompanionSettingsOperationError.unsupportedConnector(source)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CompanionSettingsOperationError.unreadableFile(
                url.path, error.localizedDescription)
        }
        return try await client.importConnector(source: source, json: data)
    }

    public func updateReason(
        _ update: CompanionReasonConfigurationUpdate
    ) async throws -> CompanionReasonSettings {
        try await client.updateReasonSettings(
            provider: update.provider, url: update.url, model: update.model,
            apiKey: update.apiKey)
    }

    public func testReason() async throws -> CompanionReasonTest {
        try await client.testReason()
    }
}

public enum CompanionSettingsOperationText {
    public static func syncGithub(_ outcome: CompanionSyncOutcome) -> String {
        "fetched \(outcome.eventsFetched) events, "
            + "\(outcome.observationsInserted) new observations"
    }

    public static func exportData(_ result: CompanionExportResult) -> String {
        let counts = result.counts.sorted { $0.key < $1.key }
        let summary = counts.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        return "exported \(summary) to \(result.directory)"
    }

    public static func importData(_ result: CompanionImportResult) -> String {
        let outcome = result.outcome
        return "restored \(outcome.episodesInserted) episode(s), "
            + "\(outcome.observationsInserted) observation(s), "
            + "\(outcome.conversationsInserted) conversation(s), "
            + "\(outcome.beliefsInserted) belief(s)"
    }

    public static func wipe(_ outcome: CompanionWipeOutcome) -> String {
        "wiped \(outcome.episodesDropped) episode(s), "
            + "\(outcome.observationsDropped) observation(s), "
            + "\(outcome.beliefsDropped) belief(s), "
            + "\(outcome.conversationsDropped) conversation(s)"
    }

    public static func reindex(_ result: CompanionReindexResult) -> String {
        "dropped \(result.maintenance.chunksDropped ?? 0) chunks, then indexed "
            + "\(result.indexing.episodesIndexed) episode(s) into "
            + "\(result.indexing.chunksCreated) chunk(s)"
    }

    public static func rebuildDerived(_ outcome: CompanionRebuildOutcome) -> String {
        "kept \(outcome.episodesKept ?? 0) episodes, dropped "
            + "\(outcome.chunksDropped ?? 0) chunks, retired "
            + "\(outcome.beliefsRetired ?? 0) beliefs"
    }

    public static func connectorImport(_ outcome: CompanionImportOutcome) -> String {
        "read \(outcome.entriesRead) entries, stored "
            + "\(outcome.observationsInserted) new observations, skipped \(outcome.skipped)"
    }

    public static func reasonTest(_ outcome: CompanionReasonTest) -> String {
        "ok in \(outcome.latencyMs) ms  (\(outcome.model))"
    }
}
