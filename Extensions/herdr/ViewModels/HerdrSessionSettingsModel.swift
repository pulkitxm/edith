import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class HerdrSessionSettingsModel {
    private let client: HerdrUIClient
    private var generation = 0
    private var stopped = false
    private var checkTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private(set) var result: HerdrSessionCheck?
    private(set) var checking = false
    private(set) var error: String?

    init(client: HerdrUIClient) { self.client = client }

    func checkSessions() {
        guard !stopped else { return }
        generation += 1
        let current = generation
        checkTask?.cancel()
        checking = true
        result = nil
        error = nil
        checkTask = Task {
            defer { if generation == current { checking = false } }
            do {
                let data = try await client.perform("herdr.settings.sessions")
                let result = try JSONDecoder().decode(HerdrSessionCheck.self, from: data)
                try result.validate()
                try Task.checkCancellation()
                guard !stopped, generation == current else { return }
                self.result = result
            } catch is CancellationError {
            } catch {
                guard !stopped, generation == current else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func openHerdr() { action("herdr.ui.navigate") }
    func openGuide() { action("herdr.settings.guide") }

    private func action(_ operation: String) {
        guard !stopped else { return }
        actionTask?.cancel()
        actionTask = Task {
            do {
                _ = try await client.perform(operation)
                try Task.checkCancellation()
                guard !stopped else { return }
                error = nil
            } catch is CancellationError {
            } catch {
                guard !stopped else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func shutdown() {
        stopped = true
        generation += 1
        checkTask?.cancel()
        actionTask?.cancel()
        checkTask = nil
        actionTask = nil
        checking = false
        client.stop()
    }
}
