import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class HerdrSettingsModel {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let invoke: Invoke
    private var generation = 0
    private var stopped = false
    private var work: Task<Void, Never>?
    private(set) var settings = HerdrAttentionSettings()
    private(set) var loading = false
    private(set) var error: String?

    init(invoke: @escaping Invoke) { self.invoke = invoke }
    convenience init(client: ExtensionEngineClient) {
        self.init { operation, payload in try await client.invoke(operation, payload: payload) }
    }

    func read() async { await perform("herdr.settings.read", payload: Data("{}".utf8)) }

    func update(_ change: (inout HerdrAttentionSettings) -> Void) {
        guard !stopped, !loading else { return }
        var next = settings
        change(&next)
        next.stuckMinutes = min(120, max(2, next.stuckMinutes))
        guard let data = try? AgentPayload.encode(next) else { return }
        work?.cancel()
        work = Task { await perform("herdr.settings.save", payload: data) }
    }

    private func perform(_ operation: String, payload: Data) async {
        guard !stopped else { return }
        generation += 1
        let current = generation
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            let data = try await invoke(operation, payload)
            try Task.checkCancellation()
            let settings = try AgentPayload.decode(HerdrAttentionSettings.self, from: data)
            guard (2...120).contains(settings.stuckMinutes) else {
                throw ExtensionPeerError.invalidRequest
            }
            guard !stopped, current == generation else { return }
            self.settings = settings
        } catch is CancellationError {
        } catch {
            guard !stopped, current == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func shutdown() {
        stopped = true
        generation += 1
        work?.cancel()
        work = nil
        loading = false
    }
}
