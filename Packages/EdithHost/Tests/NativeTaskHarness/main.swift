import Darwin
import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation

@main @MainActor struct HostNativeTaskHarness {
    static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else { throw HostWorkerError.rejected }
        let root = URL(fileURLWithPath: arguments[0])
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[1]), to: app)
        let identifier = "com.pulkit.edith.tests.native-\(UUID().uuidString)"
        let info = app.appendingPathComponent("Contents/Info.plist")
        var plist =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
            as! [String: Any]
        plist["CFBundleIdentifier"] = identifier
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: info)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        try sign.run(); sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw MarketplaceError.invalidSignature }
        let identity = try HostIdentity(identifier: identifier, supportDirectory: root)
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let package = ExtensionPackage(
            id: "keepAwake", version: "1.0.0", hostABI: HostContract.compatibility,
            downloadURL: URL(
                string: "https://github.com/pulkitxm/edith/releases/download/fixture/keepAwake.zip")!,
            sha256: String(repeating: "0", count: 64), downloadBytes: 1, installedBytes: 1)
        let bundle = store.directory(for: package).appendingPathComponent("keepAwake/app.bundle")
        try FileManager.default.createDirectory(
            at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: bundle)
        try store.commit([package])
        let defaults = UserDefaults(suiteName: identity.defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: identity.defaultsSuite) }
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: app.appendingPathComponent("Contents/MacOS/Edith"))
        }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: identifier, owner: "keepAwake",
            directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
        let data = identity.extensionDirectory("keepAwake")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try await sessions.enable(package)
        let echoed = try await call(endpoint, "native.echo")
        guard echoed["status"] as? Int == 7,
            echoed["output"] as? String == Data([0, 1, 127, 128, 255, 10]).base64EncodedString(),
            echoed["error"] as? String == ""
        else { throw HostWorkerError.invalidResponse }
        defaults.set([], forKey: "enabledExtensions")
        let denied = try await call(endpoint, "native.echo")
        guard denied["status"] as? Int == 1, denied["output"] as? String == "" else {
            throw HostWorkerError.invalidResponse
        }
        defaults.set(["keepAwake"], forKey: "enabledExtensions")
        for command in ["native.malformed", "native.oversize", "native.contextMismatch"] {
            let denied = try await call(endpoint, command)
            guard denied["status"] as? Int == 1 else { throw HostWorkerError.invalidResponse }
        }
        let incompatible = ExtensionPackage(
            id: package.id, version: package.version, hostABI: "incompatible-host-abi",
            downloadURL: package.downloadURL, sha256: package.sha256,
            downloadBytes: package.downloadBytes, installedBytes: package.installedBytes)
        try store.commit([incompatible])
        let incompatibleResult = try await call(endpoint, "native.echo")
        guard incompatibleResult["status"] as? Int == 1,
            incompatibleResult["output"] as? String == ""
        else {
            throw HostWorkerError.invalidResponse
        }
        try store.commit([])
        let uninstalledResult = try await call(endpoint, "native.echo")
        guard uninstalledResult["status"] as? Int == 1, uninstalledResult["output"] as? String == ""
        else {
            throw HostWorkerError.invalidResponse
        }
        try store.commit([package])
        let unowned = Process()
        unowned.executableURL = app.appendingPathComponent("Contents/MacOS/Edith")
        unowned.arguments = ["--extension-native-task", Data([1]).base64EncodedString()]
        unowned.environment = ["EDITH_EXTENSION_WORKER": "1"]
        unowned.standardInput = FileHandle.nullDevice
        unowned.standardOutput = FileHandle.nullDevice
        unowned.standardError = FileHandle.nullDevice
        try unowned.run(); unowned.waitUntilExit()
        guard unowned.terminationStatus == 1 else { throw HostWorkerError.invalidResponse }
        let returned = try await call(endpoint, "native.returnWithChild")
        guard returned["status"] as? Int == 9 else { throw HostWorkerError.invalidResponse }
        let returnedChild = try pid(data.appendingPathComponent("native-child.pid"))
        try await wait { kill(returnedChild, 0) == -1 && kill(-returnedChild, 0) == -1 }
        for mode in ["cancel", "parentExit"] {
            try? FileManager.default.removeItem(at: data.appendingPathComponent("native-child.pid"))
            _ = try await call(endpoint, "native.launch")
            try await wait {
                FileManager.default.fileExists(
                    atPath: data.appendingPathComponent("native-child.pid").path)
            }
            let native = try pid(data.appendingPathComponent("native.pid"))
            let child = try pid(data.appendingPathComponent("native-child.pid"))
            if mode == "cancel" {
                _ = try await call(endpoint, "native.cancel")
            } else {
                kill(sessions.processIdentifiers["keepAwake"]!, SIGKILL)
            }
            try await wait { kill(native, 0) == -1 && kill(child, 0) == -1 }
            guard kill(-native, 0) == -1, kill(-child, 0) == -1 else {
                throw HostWorkerError.invalidResponse
            }
        }
        await sessions.shutdown()
        try await sessions.enable(package)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Runtime")
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        let tampered = try await call(endpoint, "native.echo")
        guard tampered["status"] as? Int == 1, tampered["output"] as? String == "" else {
            throw HostWorkerError.invalidResponse
        }
        try await sessions.disable(id: "keepAwake")
        guard sessions.processIdentifiers.isEmpty else { throw HostWorkerError.invalidResponse }
        print(
            "{\"sameAppExecutable\":true,\"binaryStdio\":true,\"disabledAdmission\":true,\"malformedAdmission\":true,\"oversizeAdmission\":true,\"contextAdmission\":true,\"incompatibleAdmission\":true,\"uninstalledAdmission\":true,\"unownedAdmission\":true,\"tamperedAdmission\":true,\"parentExitCleanup\":true,\"cancelledDescendants\":true,\"normalReturnCleanup\":true,\"remainingProcesses\":0}"
        )
    }

    private static func call(_ endpoint: ExtensionPeerEndpoint, _ command: String) async throws
        -> [String: Any]
    {
        let data = try await endpoint.invoke(command, payload: Data("{}".utf8), timeout: 15)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HostWorkerError.invalidResponse
        }
        return object
    }
    private static func pid(_ url: URL) throws -> Int32 {
        guard let value = Int32(try String(contentsOf: url, encoding: .utf8)), value > 1 else {
            throw HostWorkerError.invalidResponse
        }
        return value
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !predicate() {
            guard Date() < deadline else { throw HostWorkerError.rejected }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
