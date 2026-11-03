import AppKit
import Darwin
import EdithExtensionCore
import EdithHostCore
import ExtensionMarketplace
import Foundation

@main
struct CrashRecoveryProof {
    @MainActor static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Crash recovery proof failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else { throw CocoaError(.coderReadCorrupt) }
        let mode = arguments[0]
        let root = URL(fileURLWithPath: arguments[1])
        guard let identifier = Bundle.main.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.crash-")
        else { throw CocoaError(.fileReadNoPermission) }
        if mode == "abi" {
            print(HostContract.compatibility)
            return
        }
        let identity = try HostIdentity(
            identifier: identifier, supportDirectory: root.appendingPathComponent("support"))
        let defaults = UserDefaults(suiteName: identity.defaultsSuite)!
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let packages = try store.installedPackages()
        if mode == "seed" {
            defaults.set(
                ["crashProbe", "healthyProbe"], forKey: HostExtensionSessions.enabledExtensionsKey)
            defaults.removeObject(forKey: HostExtensionSessions.startingKey)
            defaults.removeObject(forKey: HostExtensionSessions.probationKey)
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            return
        }
        if mode == "inspect" {
            try emit([
                "starting": defaults.stringArray(forKey: HostExtensionSessions.startingKey) ?? [],
                "probation": defaults.string(forKey: HostExtensionSessions.probationKey) as Any?
                    ?? NSNull(),
                "enabled": defaults.stringArray(forKey: HostExtensionSessions.enabledExtensionsKey)
                    ?? [],
            ])
            return
        }
        guard mode == "launch" else { throw CocoaError(.coderReadCorrupt) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version))
        }
        await sessions.restore(
            packages: Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) }))
        let endpoint = try ExtensionPeerEndpoint(
            namespace: identity.identifier, owner: "healthyProbe",
            directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
        let payload = Data("{\"message\":\"synthetic echo\"}".utf8)
        let reply = try await endpoint.invoke("healthyProbe.echo", payload: payload, timeout: 5)
        guard reply == payload else { throw CocoaError(.coderReadCorrupt) }
        let report: [String: Any] = [
            "states": sessions.states.mapValues(\.rawValue),
            "enabled": sessions.enabledIDs.sorted(),
            "failureReasons": sessions.failureReasons,
            "healthyEcho": String(decoding: reply, as: UTF8.self),
            "starting": defaults.stringArray(forKey: HostExtensionSessions.startingKey) ?? [],
            "probation": defaults.string(forKey: HostExtensionSessions.probationKey) as Any?
                ?? NSNull(),
        ]
        guard await sessions.shutdown() else { throw CocoaError(.fileWriteUnknown) }
        try emit(report)
    }

    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
