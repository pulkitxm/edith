import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class HerdrSessionSettingsModel {
    private let client: HerdrUIClient
    private var generation = 0
    private var stopped = false
    private var checkTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var pendingCheck: Int?
    private var pendingAction: (String, UUID)?
    private var actionToken: UUID?
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
        pendingCheck = current
        startCheck()
    }

    private func startCheck() {
        guard !stopped, checkTask == nil, let current = pendingCheck else { return }
        pendingCheck = nil
        checkTask = Task { [self] in
            defer {
                checkTask = nil
                startCheck()
            }
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
        let token = UUID()
        actionToken = token
        pendingAction = (operation, token)
        startAction()
    }

    private func startAction() {
        guard !stopped, actionTask == nil, let (operation, token) = pendingAction else { return }
        pendingAction = nil
        actionTask = Task { [self] in
            defer {
                actionTask = nil
                startAction()
            }
            do {
                _ = try await client.perform(operation)
                try Task.checkCancellation()
                guard !stopped, actionToken == token else { return }
                error = nil
            } catch is CancellationError {
            } catch {
                guard !stopped, actionToken == token else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func stopAndWait() async {
        shutdown()
        await checkTask?.value
        await actionTask?.value
    }

    func shutdown() {
        stopped = true
        generation += 1
        checkTask?.cancel()
        actionTask?.cancel()
        pendingCheck = nil
        pendingAction = nil
        actionToken = nil
        checking = false
        client.stop()
    }
}
