import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor
final class JevCommands {
    let engine: JevEngine
    private let registry = ExtensionCommandRegistry()
    private let cliStreams = try? ExtensionCLIStreams(owner: "jev")
    private var stopped = false

    init(engine: JevEngine? = nil) {
        let state = ExtensionSharedState.current
        self.engine =
            engine
            ?? JevEngine(
                store: JevKeyStores.make(),
                onKeyChange: { configured in
                    try? state?.publish(["configured": configured ? "1" : "0"])
                })
    }

    func invoke(_ request: NSDictionary, completion: @escaping ExtensionCommandRegistry.Completion)
    {
        guard !stopped else { completion(nil, "The extension is disabled."); return }
        registry.invoke(request, completion: completion) { [engine] command, payload in
            if command == "jev.cli.catalog" { return try JevCLICatalog.data() }
            if command.hasPrefix("jev.cli.stream.") {
                guard let cliStreams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try JevCLIEnvironment.$streamOwner.withValue(JevCLIEngine(engine: engine)) {
                    try cliStreams.invoke(
                        JevCommand.self, operation: command, prefix: "jev.cli.stream",
                        payload: payload)
                }
            }
            switch command {
            case "jev.cli":
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await JevCLIExecution.run(request, engine: engine))
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

    func shutdownAndWait() async {
        stopped = true
        await registry.shutdownAndWait()
        await cliStreams?.stopAndWait()
    }

    func shutdown() {
        stopped = true
        registry.shutdown(); cliStreams?.stop()
    }
}
