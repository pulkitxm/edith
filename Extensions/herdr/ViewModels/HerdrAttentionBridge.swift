import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class HerdrAttentionBridge {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let active: @MainActor () -> Bool
    private let privateMode: @MainActor () -> Bool
    private let invoke: Invoke
    private(set) var stopped = false
    init(
        active: @escaping @MainActor () -> Bool = {
            SurfaceHostContext.current?.activeIDs.contains("attention") == true
        },
        privateMode: @escaping @MainActor () -> Bool = {
            ExtensionSharedState.current?.values(for: "presenter")["active"] == "1"
        },
        invoke: @escaping Invoke = { command, payload in
            guard let endpoint = ExtensionPeerEndpoint.current(owner: "attention") else {
                throw ExtensionPeerError.unavailable
            }
            return try await endpoint.invoke(command, payload: payload, timeout: 15)
        }
    ) {
        self.active = active
        self.privateMode = privateMode
        self.invoke = invoke
    }
    func forward(hosts: [HerdrHostSnapshot], focused: HerdrAgent?, view: String, bundleID: String)
        async throws
    {
        guard !stopped, active() else { return }
        try Task.checkCancellation()
        let hidden = privateMode()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var remaining = 512
        var payloadBytes = 0
        var seen = Set<String>()
        let records =
            hidden
            ? []
            : hosts.prefix(64).map { host -> Host in
                var agents: [Agent] = []
                for agent in host.agents where remaining > 0 {
                    let id = stableID(agent.id)
                    guard seen.insert(id).inserted else { continue }
                    let record = Agent(
                        id: id,
                        kind: HerdrWorker.bounded(HerdrKind.displayName(for: agent.kind), 128),
                        machineName: HerdrWorker.bounded(agent.machineName, 256),
                        cwd: HerdrWorker.bounded(agent.cwd, 4096),
                        title: HerdrWorker.bounded(agent.title, 1024),
                        status: agent.status == .done
                            ? "finished"
                            : agent.status == .unknown ? "idle" : agent.status.rawValue,
                        isTerminal: agent.isTerminal)
                    let encoded = try? encoder.encode(record)
                    guard let encoded, payloadBytes + encoded.count + 64 <= 900_000 else {
                        continue
                    }
                    agents.append(record)
                    payloadBytes += encoded.count + 64
                    remaining -= 1
                }
                return Host(reachable: host.reachable, agents: agents)
            }
        let data = try encoder.encode(Batch(hosts: records))
        guard data.count <= 1_048_576, !stopped, active() else { return }
        _ = try await invoke("attention.agents.record", data)
        try Task.checkCancellation()
        guard !stopped, active() else { return }
        var tags = ["page": "herdr", "view": HerdrWorker.bounded(view, 500)]
        if let focused, !hidden {
            tags["machine"] = HerdrWorker.bounded(focused.machineName, 500)
            tags["agent"] = HerdrWorker.bounded(HerdrKind.displayName(for: focused.kind), 500)
            tags["project"] = HerdrWorker.bounded(focused.workspace, 500)
            tags["session"] = HerdrWorker.bounded(focused.session, 500)
        }
        let context = Context(
            bundleID: HerdrWorker.bounded(bundleID, 256), tags: tags,
            windowTitle: hidden ? "" : HerdrWorker.bounded(focused?.title ?? "Herdr", 1024))
        let contextData = try encoder.encode(context)
        guard contextData.count <= 8192 else { throw ExtensionPeerError.invalidRequest }
        _ = try await invoke("attention.context", contextData)
        try Task.checkCancellation()
    }
    func shutdown() { stopped = true }
    private func stableID(_ id: String) -> String {
        "herdr:" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private struct Agent: Encodable {
        let id: String
        let kind: String
        let machineName: String
        let cwd: String
        let title: String
        let status: String
        let isTerminal: Bool
    }
    private struct Host: Encodable { let reachable: Bool; let agents: [Agent] }
    private struct Batch: Encodable { let hosts: [Host] }
    private struct Context: Encodable {
        let bundleID: String; let tags: [String: String]; let windowTitle: String
    }
}
