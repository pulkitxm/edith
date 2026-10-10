@_implementationOnly import EdithExtensionSupport_attention_native
import Foundation
import SwiftUI

struct AttentionUIStatus: Codable, Sendable {
    var extensionInstalled = false
    var browserConnected = false
    var backupAvailable = false
    var lastBackupAt: Date?
}

struct AttentionUIBreakdownRequest: Codable, Sendable {
    var summary: AttentionSummaryRequest
    var dimension: String
    var level: AttentionProductivity?
    var sphere: AttentionSphere?
    var category: String?
    var search: String
    var sort: String
}

@MainActor final class AttentionUIClient {
    private let send: @MainActor (String, Data) async throws -> Data
    private let invalidate: @MainActor () -> Void
    let available: Bool
    private(set) var stopped = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var generation = 0

    convenience init(engine: ExtensionEngineClient) {
        self.init(
            send: { try await engine.invoke($0, payload: $1) }, invalidate: { engine.invalidate() })
    }
    init(
        send: @escaping @MainActor (String, Data) async throws -> Data,
        invalidate: @escaping @MainActor () -> Void = {}, available: Bool = true
    ) {
        self.send = send
        self.invalidate = invalidate
        self.available = available
    }
    func invoke(_ operation: String, payload: Data = Data("{}".utf8)) async throws -> Data {
        let current = generation
        guard available, !stopped else { throw ExtensionPeerError.unavailable }
        guard
            [
                "attention.ui.summary", "attention.ui.status", "attention.ui.focus.get",
                "attention.ui.focus.start", "attention.ui.focus.stop", "attention.settings.set",
                "attention.ui.extension.install", "attention.ui.extension.open",
                "attention.ui.token.copy",
                "attention.ui.accessibility", "attention.ui.breakdown.copy",
                "attention.ui.application.icon",
                "attention.categorize", "attention.backup", "attention.restore",
                AgentFaviconClient.operation,
            ].contains(operation)
        else { throw ExtensionPeerError.invalidRequest }
        let value = try await send(operation, payload)
        try Task.checkCancellation()
        guard !stopped, current == generation else { throw CancellationError() }
        return value
    }
    func snapshot(_ request: AttentionSummaryRequest) async throws -> AttentionPageSnapshot {
        try AttentionPayload.decode(
            AttentionPageSnapshot.self,
            from: await invoke("attention.ui.summary", payload: AttentionPayload.encode(request)))
    }
    func status() async throws -> AttentionUIStatus {
        try AttentionPayload.decode(
            AttentionUIStatus.self, from: await invoke("attention.ui.status"))
    }
    func perform(
        _ operation: String, payload: Data = Data("{}".utf8),
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        guard !stopped else { return }
        guard available else { completion(.failure(ExtensionPeerError.unavailable)); return }
        guard tasks.count < 8 else { completion(.failure(ExtensionPeerError.unavailable)); return }
        let id = UUID()
        let current = generation
        let previous = tail
        let task = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            await previous?.value
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let value = try await self.invoke(operation, payload: payload)
                guard !Task.isCancelled, !self.stopped, current == self.generation else { return }
                completion(.success(value))
            } catch {
                guard !Task.isCancelled, !self.stopped, current == self.generation else { return }
                completion(.failure(error))
            }
        }
        tasks[id] = task
        tail = task
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        tail?.cancel(); tail = nil
        invalidate()
    }
}

private struct AttentionUIClientKey: EnvironmentKey {
    static let defaultValue: AttentionUIClient? = nil
}
extension EnvironmentValues {
    var attentionUIClient: AttentionUIClient? {
        get { self[AttentionUIClientKey.self] }
        set { self[AttentionUIClientKey.self] = newValue }
    }
}
