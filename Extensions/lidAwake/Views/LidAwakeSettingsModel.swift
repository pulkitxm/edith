import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class LidAwakeSettingsModel {
    let operations: LidAwakeOperationModel
    private let client: ExtensionEngineClient
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private(set) var error: String?

    init(client: ExtensionEngineClient) {
        self.client = client
        operations = LidAwakeOperationModel { request in
            let command: String
            let payload: Data
            switch request {
            case .status: command = "lidAwake.status"; payload = Data("{}".utf8)
            case .off: command = "lidAwake.off"; payload = Data("{}".utf8)
            case .on(let session):
                command = "lidAwake.on";
                payload = try JSONEncoder().encode(["session": session.rawValue])
            case .setBatteryThreshold(let threshold):
                command = "lidAwake.battery";
                payload = try JSONEncoder().encode(["threshold": threshold])
            case .setRestoreOnQuit(let enabled):
                command = "lidAwake.restoreOnQuit";
                payload = try JSONEncoder().encode(["enabled": enabled])
            case .enableExtension, .disableExtension: throw ExtensionPeerError.invalidRequest
            }
            let data = try await client.invoke(command, payload: payload, timeout: 30)
            return try JSONDecoder().decode(LidAwakeSnapshot.self, from: data)
        }
    }

    func requestApproval() { perform("lidAwake.approval", payload: Data("{}".utf8)) }
    func setSession(_ session: LidAwakeSession) {
        guard let payload = try? JSONEncoder().encode(["session": session.rawValue]) else { return }
        perform("lidAwake.session", payload: payload)
    }
    private func perform(_ command: String, payload: Data) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do {
                _ = try await client.invoke(command, payload: payload, timeout: 30)
                guard !stopped else { return }
                error = nil
                operations.refreshStatus()
            } catch is CancellationError {} catch {
                guard !stopped else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func stop() {
        stopped = true
        operations.cancel()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
