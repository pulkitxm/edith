import EdithExtensionSupport
import Foundation

@MainActor
final class JevCommands {
    let engine: JevEngine
    private let registry = ExtensionCommandRegistry()
    private var stopped = false

    init(engine: JevEngine? = nil) {
        let state = ExtensionSharedState.current
        self.engine =
            engine
            ?? JevEngine(
                store: KeychainJevKeyStore(),
                onKeyChange: { configured in
                    try? state?.publish(["configured": configured ? "1" : "0"])
                })
    }

    func invoke(_ request: NSDictionary, completion: @escaping ExtensionCommandRegistry.Completion)
    {
        guard !stopped else { completion(nil, "The extension is disabled."); return }
        registry.invoke(request, completion: completion) { [engine] command, payload in
            switch command {
            case "surface.snapshot", "surface.perform":
                return try await SurfaceCommandService.execute(
                    providerID: "jev", command: command, payload: payload,
                    snapshot: { _ in JevSurface.snapshot(await engine.status(probe: false)) },
                    perform: { _ in throw ExtensionPeerError.invalidRequest })
            case "jev.status":
                let query = try JSONDecoder().decode(JevStatusQuery.self, from: payload)
                return try JSONEncoder().encode(await engine.status(probe: query.probe))
            case "jev.key.set":
                let update = try JSONDecoder().decode(JevKeyUpdate.self, from: payload)
                await engine.setKey(update.key)
                return try JSONEncoder().encode(await engine.status(probe: false))
            case "jev.decide":
                let call = try JSONDecoder().decode(JevCall.self, from: payload)
                do {
                    let decision = try await engine.decide(
                        call.request.validated(), purpose: call.purpose)
                    return try JSONEncoder().encode(JevReply(decision: decision))
                } catch let error as JevError {
                    return try JSONEncoder().encode(JevReply(error: error))
                }
            default: throw ExtensionPeerError.rejected("Jev does not support this command.")
            }
        }
    }

    func cancel(_ token: String) { registry.cancel(token) }

    func shutdown() {
        stopped = true
        registry.shutdown()
    }
}
