import EdithExtensionSupport
import Foundation

@MainActor final class LidAwakeSurface {
    private let worker: LidAwakeWorker
    private let privacy: @MainActor () -> [String: String]
    init(
        worker: LidAwakeWorker,
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) { self.worker = worker; self.privacy = privacy }

    func execute(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("surface.") {
            return try await SurfaceCommandService.execute(
                providerID: "lidAwake", command: command,
                payload: payload, snapshot: snapshot, perform: perform, privacyValues: privacy)
        }
        guard !SurfacePrivacyState.hides(.ability("lidAwake"), values: privacy()) else {
            throw ExtensionPeerError.unavailable
        }
        if command == "lidAwake.session" {
            struct Input: Decodable { let session: LidAwakeSession }
            try worker.setSession(JSONDecoder().decode(Input.self, from: payload).session)
            return try JSONEncoder().encode(worker.engine.snapshot())
        }
        if command == "lidAwake.approval" {
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            try worker.requestApproval()
            return try JSONEncoder().encode(worker.engine.snapshot())
        }
        let request: LidAwakeRequest
        switch command {
        case "lidAwake.status": request = .status
        case "lidAwake.on":
            struct Input: Decodable { let session: LidAwakeSession }
            request = .on(try JSONDecoder().decode(Input.self, from: payload).session)
        case "lidAwake.off": request = .off
        case "lidAwake.battery":
            struct Input: Decodable { let threshold: Int }
            request = .setBatteryThreshold(
                try JSONDecoder().decode(Input.self, from: payload).threshold)
        case "lidAwake.restoreOnQuit":
            struct Input: Decodable { let enabled: Bool }
            request = .setRestoreOnQuit(try JSONDecoder().decode(Input.self, from: payload).enabled)
        default: throw ExtensionPeerError.invalidRequest
        }
        if request == .status || request == .off {
            guard payload.isEmpty || payload == Data("{}".utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        let state = try await worker.perform(
            request, requiresConfirmation: request.operation == .on)
        return try JSONEncoder().encode(state)
    }

    private func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        let field = tile.widget == .actions ? "lidAwake" : nil
        guard field == nil || tile.shows("lidAwake") else {
            return .init(providerID: "lidAwake")
        }
        let state = worker.engine.snapshot()
        let action = state.requestedActive ? "off" : "on"
        return .init(
            providerID: "lidAwake",
            metrics: [
                .init("sleep", "Lid sleep", state.active ? "Disabled" : "Normal"),
                .init(
                    "battery", "Battery floor",
                    state.batteryThreshold == 0 ? "Off" : "\(state.batteryThreshold)%"),
            ],
            rows: [
                .init(
                    "state", sourceID: "sleep", title: state.session.title,
                    detail: state.batterySuspended
                        ? "Paused for battery safety"
                        : state.restoreOnQuit
                            ? "Sleep is restored when Edith quits"
                            : "Sleep restoration on quit is off",
                    icon: "laptopcomputer", field: field)
            ],
            actions: [
                .init(
                    action, state.requestedActive ? "Restore sleep" : "Keep awake",
                    "laptopcomputer", field: field)
            ],
            sources: [.init("sleep", "Sleep policy")], message: state.lastError)
    }

    private func perform(_ id: String) async throws {
        switch id {
        case "on": _ = try await worker.perform(.on(.indefinite), requiresConfirmation: true)
        case "off": _ = try await worker.perform(.off)
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
