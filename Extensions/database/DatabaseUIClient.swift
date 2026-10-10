import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DatabaseUIClient: DatabaseBrokerCommandSending, DatabaseSecretStore {
    @ObservationIgnored private let engine: ExtensionEngineClient
    @ObservationIgnored private var columnWriter: Task<Void, Never>?
    @ObservationIgnored private var pendingColumns: Data?
    private(set) var columns: Data?
    private(set) var privateContent = true
    private(set) var loaded = false
    private(set) var failure: String?
    private var stopped = false

    init(engine: ExtensionEngineClient) { self.engine = engine }

    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        let payload = try JSONEncoder().encode(request)
        let bytes = try await engine.invoke("database.execute", payload: payload)
        let response = try JSONDecoder().decode(DatabaseBrokerCommandResponse.self, from: bytes)
        _ = try response.envelope(
            matching: request.envelope(requestID: UUID(), sequence: 0), sequence: 0)
        return response
    }

    func load() async {
        do {
            let bytes = try await engine.invoke("database.ui.state")
            let state = try JSONDecoder().decode(DatabaseUIState.self, from: bytes)
            if let columns = state.columns {
                try DatabaseColumnsModel.validateStoredLayouts(columns)
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            columns = state.columns
            privateContent = state.privateContent
            loaded = true
            failure = nil
        } catch {
            guard !Task.isCancelled, !stopped else { return }
            privateContent = true
            failure = "Database could not load its owned workspace. Retry to reconnect."
        }
    }

    func refreshPrivacy() async {
        do {
            let bytes = try await engine.invoke("database.ui.privacy")
            let state = try JSONDecoder().decode(Bool.self, from: bytes)
            try Task.checkCancellation()
            guard !stopped else { return }
            privateContent = state
        } catch { privateContent = true }
    }

    func makeSession() -> DatabasePageSession {
        DatabasePageSession(
            sender: self,
            repair: { try await self.repair() },
            prepare: { try await self.prepare($0.id) },
            makeColumns: {
                DatabaseColumnsModel(read: { self.columns }, write: { self.persistColumns($0) })
            },
            secretStore: self)
    }

    func persistColumns(_ value: Data) {
        guard !stopped, (try? DatabaseColumnsModel.validateStoredLayouts(value)) != nil else {
            return
        }
        guard let updates = try? DatabaseColumnsModel.changedLayouts(from: columns, to: value),
            let pending = try? DatabaseColumnsModel.mergedLayouts(
                stored: pendingColumns, updates: updates)
        else { return }
        columns = value
        pendingColumns = pending
        startColumnWriter()
    }

    private func startColumnWriter() {
        guard columnWriter == nil else { return }
        columnWriter = Task { [weak self] in
            guard let self else { return }
            defer { self.columnWriter = nil }
            while let value = self.pendingColumns, !self.stopped {
                self.pendingColumns = nil
                do {
                    let bytes = try await self.engine.invoke(
                        "database.ui.columns",
                        payload: JSONEncoder().encode(DatabaseUIColumns(data: value)))
                    try Task.checkCancellation()
                    let saved = try JSONDecoder().decode(DatabaseUIColumns.self, from: bytes)
                    self.columns = try DatabaseColumnsModel.mergedLayouts(
                        stored: saved.data,
                        updates: self.pendingColumns ?? Data(#"{"version":1,"layouts":[]}"#.utf8))
                    self.failure = nil
                } catch {
                    guard !Task.isCancelled, !self.stopped else { return }
                    self.pendingColumns = try? DatabaseColumnsModel.mergedLayouts(
                        stored: value,
                        updates: self.pendingColumns ?? Data(#"{"version":1,"layouts":[]}"#.utf8))
                    self.failure =
                        "Column customization could not be saved. Retry before closing Database."
                    return
                }
            }
        }
    }

    func retryColumns() {
        guard pendingColumns != nil, columnWriter == nil else { return }
        startColumnWriter()
    }

    func flushColumns() async throws {
        if let columnWriter { await columnWriter.value }
        try Task.checkCancellation()
        guard pendingColumns == nil, !stopped else { throw ExtensionEngineError.unavailable }
    }

    func repair() async throws { _ = try await engine.invoke("database.ui.repair") }

    func prepare(_ id: DatabaseConnectionID) async throws {
        _ = try await engine.invoke(
            "database.ui.prepare",
            payload: JSONEncoder().encode(DatabaseConnectionGetRequest(connectionID: id)))
    }

    func store(_ secret: Data, for reference: DatabaseSecretReference) async throws {
        _ = try await engine.invoke(
            "database.ui.credential.store",
            payload: JSONEncoder().encode(
                DatabaseUICredential(reference: reference, secret: secret)))
    }

    func delete(_ reference: DatabaseSecretReference) async throws {
        _ = try await engine.invoke(
            "database.ui.credential.delete",
            payload: JSONEncoder().encode(DatabaseUICredential(reference: reference, secret: nil)))
    }

    func read(_ reference: DatabaseSecretReference) async throws -> Data {
        throw DatabaseBrokerCommandClientError.invalidRequest
    }

    func contains(_ reference: DatabaseSecretReference) async throws -> Bool {
        throw DatabaseBrokerCommandClientError.invalidRequest
    }

    func storeIfAbsent(_ secret: Data, for reference: DatabaseSecretReference) async throws -> Data
    {
        throw DatabaseBrokerCommandClientError.invalidRequest
    }

    func shutdown() {
        stopped = true
        columnWriter?.cancel()
        columnWriter = nil
        pendingColumns = nil
        privateContent = true
        engine.invalidate()
    }
}

private struct DatabaseRemotePrivacyKey: EnvironmentKey { static let defaultValue: Bool? = nil }

extension EnvironmentValues {
    var databaseRemotePrivacy: Bool? {
        get { self[DatabaseRemotePrivacyKey.self] }
        set { self[DatabaseRemotePrivacyKey.self] = newValue }
    }
}

@MainActor
struct DatabaseRemotePage: View {
    let client: DatabaseUIClient
    let session: DatabasePageSession

    var body: some View {
        Group {
            if client.loaded {
                DatabasePage(session: session)
                    .environment(\.databaseRemotePrivacy, client.privateContent)
                    .overlay(alignment: .top) {
                        if let failure = client.failure {
                            VStack {
                                Text(failure).font(.edithText(.callout))
                                Button("Retry") { client.retryColumns() }
                            }
                            .padding().background(.regularMaterial).clipShape(
                                RoundedRectangle(cornerRadius: 8))
                        }
                    }
            } else {
                PageScaffold {
                    PageHeader("Database")
                } content: {
                    if let failure = client.failure {
                        Text(failure)
                        Button("Retry") { Task { await client.load() } }
                    } else {
                        ProgressView("Loading owned workspace")
                    }
                }
            }
        }
        .pageTask {
            if !client.loaded { await client.load() }
            while !Task.isCancelled {
                await client.refreshPrivacy()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
