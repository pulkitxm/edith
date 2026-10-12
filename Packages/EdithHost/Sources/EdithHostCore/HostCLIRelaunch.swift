import AppKit
import EdithExtensionSupport
import Foundation

public enum HostCLIRelaunch {
    public static func run(
        bundle: URL, json: Bool, timeout: Double = 8,
        quit: @Sendable () async throws -> Void,
        running: @Sendable () -> Bool,
        launch: @Sendable (URL) async throws -> Void
    ) async throws -> ExtensionCLIReply {
        guard timeout.isFinite, timeout > 0, timeout <= 8, bundle.pathExtension == "app" else {
            throw HostCLIError.usage("Invalid relaunch target.")
        }
        try Task.checkCancellation()
        try await quit()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while running() {
            guard ContinuousClock.now < deadline else {
                throw HostCLIError.rejected("Edith did not quit, so it was not relaunched.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        try await launch(bundle)
        try Task.checkCancellation()
        return json
            ? try HostCLIOutput.json(
                .object([
                    "applied": .bool(true), "changed": .bool(true), "relaunched": .bool(true),
                    "path": .string(bundle.path),
                ])) : try HostCLIOutput.text("relaunched Edith")
    }

    static func execute(json: Bool, invoke: @escaping HostCLIProviderRegistry.Invoke) async throws
        -> ExtensionCLIReply
    {
        let data = try await invoke(
            HostCoreCLIEnvelope(arguments: ["app", "diagnostics", "--json"]).request())
        let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
        try reply.validate()
        guard reply.exitCode == 0,
            let value = try JSONDecoder().decode(HostCLIJSON.self, from: Data(reply.stdout.utf8))
                .object,
            let number = value["pid"]?.integer, number > 1, number <= Int64(Int32.max),
            let path = value["info"]?.object?["bundlePath"]?.string,
            path == Bundle.main.bundleURL.path,
            value["info"]?.object?["bundleID"]?.string == Bundle.main.bundleIdentifier,
            let peer = HostCLIProcess.read(Int32(number)),
            let current = HostCLIProcess.read(getpid()),
            peer.executable == current.executable, peer.codeHash == current.codeHash
        else {
            throw HostCLIError.rejected(
                "The matching Edith app could not be identified for relaunch.")
        }
        return try await run(
            bundle: URL(fileURLWithPath: path), json: json,
            quit: {
                let data = try await invoke(
                    HostCoreCLIEnvelope(arguments: ["app", "quit", "--yes", "--json"]).request())
                let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
                try reply.validate()
                guard reply.exitCode == 0 else { throw HostCLIError.rejected(reply.stderr) }
            }, running: { HostCLIProcess.read(peer.pid) == peer },
            launch: { url in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await NSWorkspace.shared.openApplication(
                    at: url, configuration: configuration)
            })
    }
}
