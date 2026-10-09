import Darwin
import EdithHostCore
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@main
struct HostCommandHarness {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else { throw HostWorkerError.rejected }
        let root = URL(fileURLWithPath: arguments[0])
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[1]), to: app)
        let identifier = "com.pulkit.edith.tests.command-\(UUID().uuidString)"
        let info = app.appendingPathComponent("Contents/Info.plist")
        var plist =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)
            as! [String: Any]
        plist["CFBundleIdentifier"] = identifier
        plist["CFBundleName"] = "Command Fixture"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: info)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", app.path]
        try signer.run()
        signer.waitUntilExit()
        guard signer.terminationStatus == 0 else { throw MarketplaceError.invalidSignature }
        let executable = app.appendingPathComponent("Contents/MacOS/Edith")
        let identity = try HostIdentity(identifier: identifier, supportDirectory: root)
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let package = ExtensionPackage(
            id: "keepAwake", version: "1.0.0", hostABI: HostContract.compatibility,
            downloadURL: URL(
                string: "https://github.com/pulkitxm/edith/releases/download/fixture/keepAwake.zip")!,
            sha256: String(repeating: "0", count: 64), downloadBytes: 1, installedBytes: 1)
        let directory = store.directory(for: package).appendingPathComponent(package.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: arguments[2]),
            to: directory.appendingPathComponent("helper.bundle"))
        try store.commit([package])
        let suite = identity.extensionDefaultsSuite(package.id)
        guard let defaults = UserDefaults(suiteName: suite) else { throw HostWorkerError.rejected }
        defer { defaults.removePersistentDomain(forName: suite) }
        for mode in ["disable", "crash", "hang", "completed"] {
            defaults.set(mode, forKey: "commandFixtureMode")
            let data = identity.extensionDirectory(package.id)
            try? FileManager.default.removeItem(at: data)
            let worker = HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: executable, requestTimeout: .seconds(2))
            do {
                try await worker.start()
                guard let pid = worker.processIdentifier else { throw HostWorkerError.rejected }
                try await wait {
                    FileManager.default.fileExists(
                        atPath: data.appendingPathComponent("child.pid").path)
                }
                let sharedState = ExtensionSharedState(
                    root: identity.root.appendingPathComponent("ExtensionState"),
                    namespace: identifier)
                guard sharedState.values(for: package.id) == ["busy": "1"] else {
                    throw HostWorkerError.rejected
                }
                let parent = try readPID(data.appendingPathComponent("parent.pid"))
                let child = try readPID(data.appendingPathComponent("child.pid"))
                let probe =
                    try JSONSerialization.jsonObject(
                        with: Data(contentsOf: data.appendingPathComponent("probe.json")))
                    as! [String: Any]
                guard probe["terminationStatus"] as? Int == 0,
                    probe["standardOutputData"] as? String
                        == Data([0, 1, 127, 128, 255, 10]).base64EncodedString(),
                    let encoded = probe["standardErrorData"] as? String,
                    let error = Data(base64Encoded: encoded)
                else { throw HostWorkerError.rejected }
                let values = String(decoding: error, as: UTF8.self).split(separator: "|").map(
                    String.init)
                guard values.count == 4, values[0] == String(pid), values[1] == "fixture value",
                    URL(fileURLWithPath: values[2]).resolvingSymlinksInPath()
                        == data.resolvingSymlinksInPath(),
                    values[3] == "literal \"quoted\" value"
                else { throw HostWorkerError.rejected }
                if mode == "completed" {
                    try await wait {
                        FileManager.default.fileExists(
                            atPath: data.appendingPathComponent("result.json").path)
                    }
                } else {
                    guard getpgid(parent) == parent, getpgid(child) == parent else {
                        throw HostWorkerError.rejected
                    }
                }
                if mode == "crash" {
                    kill(pid, SIGKILL)
                } else {
                    try await worker.stop()
                }
                try await wait {
                    [pid, parent, child].allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
                }
                print(
                    "{\"mode\":\"\(mode)\",\"sameAppExecutable\":true,\"binaryInput\":true,\"argumentsAndEnvironment\":true,\"remainingProcesses\":0}"
                )
            } catch {
                try? await worker.stop()
                throw error
            }
        }
    }

    private static func readPID(_ file: URL) throws -> Int32 {
        guard
            let pid = Int32(
                try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .newlines))
        else {
            throw HostWorkerError.rejected
        }
        return pid
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
