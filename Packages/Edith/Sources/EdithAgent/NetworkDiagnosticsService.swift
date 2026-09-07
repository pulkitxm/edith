import EdithKit
import Foundation
import GRDB

actor NetworkDiagnosticsService {
    private let store: AgentStore
    private let engine: NetworkDiagnosticsEngine
    private var lastScheduled: Date?
    private var lastState: NetworkDiagnosticState?
    private var running: Task<NetworkDiagnosticSnapshot, Never>?

    init(store: AgentStore, engine: NetworkDiagnosticsEngine = NetworkDiagnosticsEngine()) {
        self.store = store
        self.engine = engine
    }

    func register(on runtime: AgentRuntime) async {
        await runtime.register(
            operation: NetworkDiagnosticOperation.diagnose.descriptor.id.rawValue
        ) { payload in
            try await self.diagnose(
                AgentPayload.decode(NetworkDiagnosticRequest.self, from: payload))
        }
        await runtime.register(
            operation: NetworkDiagnosticOperation.baseline.descriptor.id.rawValue
        ) { _ in
            try AgentPayload.encode(NetworkDiagnosticsPreferences.baseline())
        }
        await runtime.register(operation: NetworkDiagnosticsClient.timelineOperation) { payload in
            try await self.timeline(limit: AgentPayload.decode(Int.self, from: payload))
        }
        await runtime.register(operation: NetworkDiagnosticsClient.saveBaselineOperation) {
            payload in
            let snapshot = try AgentPayload.decode(NetworkDiagnosticSnapshot.self, from: payload)
            guard snapshot.state == .healthy else {
                throw AgentError(.refused, "Only healthy snapshots can be saved as a baseline.")
            }
            NetworkDiagnosticsPreferences.saveBaseline(snapshot)
            return Data()
        }
        await runtime.registerShutdown(id: "network.diagnostics") { await self.stop() }
    }

    func stop() { running?.cancel() }

    func scheduled() async throws -> Data? {
        let configuration = NetworkDiagnosticsPreferences.configuration()
        guard configuration.scheduledSamplingEnabled else { return nil }
        if let lastScheduled,
            Date().timeIntervalSince(lastScheduled)
                < Double(configuration.sampleIntervalMinutes * 60)
        {
            return nil
        }
        lastScheduled = Date()
        let data = try await diagnose(
            NetworkDiagnosticRequest(
                configuration: configuration, keepHistory: true, saveBaseline: false))
        let snapshot = try AgentPayload.decode(NetworkDiagnosticSnapshot.self, from: data)
        if configuration.notificationsEnabled, let lastState, lastState != snapshot.state,
            snapshot.state == .failed || lastState == .failed
        {
            try await AgentNotificationService.shared.enqueue(
                AgentNotification(
                    identifier: "network.diagnostics.state", title: "Network state changed",
                    body: "Diagnostics now report \(snapshot.state.rawValue)."))
        }
        lastState = snapshot.state
        return data
    }

    func diagnose(_ request: NetworkDiagnosticRequest) async throws -> Data {
        guard running == nil else {
            throw AgentError(.unavailable, "A network diagnostic is already running.")
        }
        let configuration = request.configuration.normalized
        let baseline = NetworkDiagnosticsPreferences.baseline()
        let task = Task { await engine.diagnose(configuration: configuration, baseline: baseline) }
        running = task
        defer { running = nil }
        let snapshot = await task.value
        try Task.checkCancellation()
        if task.isCancelled { throw CancellationError() }
        let data = try AgentPayload.encode(snapshot)
        if request.keepHistory {
            try store.write { database in
                try database.execute(
                    sql:
                        "INSERT INTO network_diagnostic (id, capturedAt, payload) VALUES (?, ?, ?)",
                    arguments: [snapshot.id.uuidString, Date(), data])
                try database.execute(
                    sql:
                        "DELETE FROM network_diagnostic WHERE id NOT IN (SELECT id FROM network_diagnostic ORDER BY capturedAt DESC LIMIT ?)",
                    arguments: [configuration.timelineLimit])
            }
        }
        if request.saveBaseline {
            guard snapshot.state == .healthy else {
                throw AgentError(.refused, "Only healthy snapshots can be saved as a baseline.")
            }
            NetworkDiagnosticsPreferences.saveBaseline(snapshot)
        }
        return data
    }

    func timeline(limit: Int) throws -> Data {
        let rows = try store.read { database in
            try Data.fetchAll(
                database,
                sql: "SELECT payload FROM network_diagnostic ORDER BY capturedAt DESC LIMIT ?",
                arguments: [max(1, min(limit, 1000))])
        }
        return try AgentPayload.encode(
            rows.map { try AgentPayload.decode(NetworkDiagnosticSnapshot.self, from: $0) })
    }
}
