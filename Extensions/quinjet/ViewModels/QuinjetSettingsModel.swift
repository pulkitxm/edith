import EdithExtensionSupport
import Foundation
import Observation

struct QuinjetSettingsPreference: Codable, Equatable {
    let terminal: String
    let theme: String
}

struct QuinjetSettingsState: Codable {
    let preference: QuinjetSettingsPreference
    let themes: [String]
    let cmuxAvailable: Bool

    func validate() throws {
        guard QuinjetTerminal(rawValue: preference.terminal) != nil, !themes.isEmpty,
            themes.count <= 256, Set(themes).count == themes.count,
            themes.allSatisfy({
                QuinjetTheme(rawValue: $0) != nil && $0.utf8.count <= 256 && !$0.utf8.contains(0)
            }),
            preference.theme == QuinjetThemePreference.app || themes.contains(preference.theme)
        else { throw ExtensionPeerError.invalidRequest }
    }
}

@MainActor @Observable final class QuinjetSettingsModel {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let requests: OwnedEngineRequests
    private var stopped = false
    private var generation = 0
    private var work: Task<Void, Never>?
    private(set) var state: QuinjetSettingsState?
    private(set) var loading = false
    private(set) var error: String?

    init(invoke: @escaping Invoke) { requests = OwnedEngineRequests(invoke: invoke) }
    convenience init(client: ExtensionEngineClient) {
        self.init { try await client.invoke($0, payload: $1) }
    }

    func read() async { await perform("quinjet.settings.read", payload: Data("{}".utf8)) }

    func setTerminal(_ value: String) { update(terminal: value, theme: nil) }
    func setTheme(_ value: String) { update(terminal: nil, theme: value) }

    private func update(terminal: String?, theme: String?) {
        guard !stopped, !loading, let state else { return }
        let next = QuinjetSettingsPreference(
            terminal: terminal ?? state.preference.terminal, theme: theme ?? state.preference.theme)
        guard
            let payload = try? JSONEncoder().encode(
                QuinjetSettingsMutation(baseline: state.preference, preference: next))
        else { return }
        work?.cancel()
        work = Task { await perform("quinjet.settings.save", payload: payload) }
    }

    private func perform(_ operation: String, payload: Data) async {
        guard !stopped else { return }
        generation += 1
        let current = generation
        loading = true
        error = nil
        defer { if generation == current { loading = false } }
        do {
            let data = try await requests.perform(operation, payload: payload)
            let value = try JSONDecoder().decode(QuinjetSettingsState.self, from: data)
            try value.validate()
            try Task.checkCancellation()
            guard !stopped, generation == current else { return }
            state = value
        } catch is CancellationError {
        } catch {
            guard !stopped, generation == current else { return }
            self.error = error.localizedDescription
        }
    }

    func shutdown() {
        stopped = true
        generation += 1
        work?.cancel(); work = nil
        requests.stop()
        loading = false
    }
}

struct QuinjetSettingsMutation: Codable {
    let baseline: QuinjetSettingsPreference
    let preference: QuinjetSettingsPreference
}
