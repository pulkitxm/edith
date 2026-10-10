import CryptoKit
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
        let app = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        guard app == root.appendingPathComponent("Fixture.app").standardizedFileURL,
            let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier,
            identifier.hasPrefix("com.pulkit.edith.tests.command-"),
            HostContract.compatibility == "edith-host-2"
        else {
            throw NSError(
                domain: "ExtensionFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Host identity mismatch: app=\(app), expected=\(root.appendingPathComponent("Fixture.app").standardizedFileURL), identifier=\(Bundle(url: app)?.bundleIdentifier ?? "missing"), ABI=\(HostContract.compatibility)"
                ])
        }
        try ExtensionCodeSignature.verifyDevelopment(app)
        let executable = app.appendingPathComponent("Contents/MacOS/Edith")
        let identity = try HostIdentity(identifier: identifier, supportDirectory: root)
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        let package = ExtensionPackage(
            id: "keepAwake", version: "1.0.0", hostABI: HostContract.compatibility,
            downloadURL: URL(
                string: "https://github.com/pulkitxm/edith/releases/download/fixture/keepAwake.zip")!,
            sha256: String(repeating: "0", count: 64), downloadBytes: 1, installedBytes: 1)
        let directory = store.directory(for: package).appendingPathComponent(package.id)
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[2]), to: directory)
        let carrier = try verifyCarrier(
            directory: directory, store: store, package: package,
            identifier: identifier, executable: executable)
        try store.commit([package])
        let suite = identity.extensionDefaultsSuite(package.id)
        guard let defaults = UserDefaults(suiteName: suite) else { throw HostWorkerError.rejected }
        defer { defaults.removePersistentDomain(forName: suite) }
        for mode in ["disable", "crash", "hang", "completed", "asyncStop", "asyncHang"] {

            defaults.set(mode, forKey: "commandFixtureMode")
            let data = identity.extensionDirectory(package.id)
            try? FileManager.default.removeItem(at: data)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let log = data.appendingPathComponent("worker.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let errorOutput = try FileHandle(forWritingTo: log)
            defer { try? errorOutput.close() }
            let worker = HostWorker(
                configuration: HostWorkerConfiguration(
                    identity: identity, extensionID: package.id, version: package.version),
                executable: executable, requestTimeout: .seconds(2), errorOutput: errorOutput)
            var stage = "start"
            do {
                try await worker.start()
                stage = "child command"
                guard let pid = worker.processIdentifier,
                    try executablePath(pid) == canonicalPath(executable)
                else { throw HostWorkerError.rejected }
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
                let endpoint = try ExtensionPeerEndpoint(
                    namespace: identifier, owner: package.id,
                    directory: identity.root.appendingPathComponent("ExtensionState/Commands"))
                stage = "peer commands"
                let description =
                    try JSONSerialization.jsonObject(
                        with: await endpoint.invoke("fixture.identity")) as? [String: Any]
                guard description?["pid"] as? Int32 == pid,
                    description?["id"] as? String == package.id,
                    description?["version"] as? String == package.version,
                    description?["hostABI"] as? String == HostContract.compatibility,
                    description?["role"] as? String == "helper",
                    let loadedPath = description?["bundlePath"] as? String,
                    try canonicalPath(URL(fileURLWithPath: loadedPath))
                        == canonicalPath(store.roleBundle(for: package, role: .helper)),
                    carrier.hostExecutablePath == (try canonicalPath(executable))
                else { throw HostWorkerError.invalidResponse }
                try await verifyCommands(endpoint, data: data)
                let pending = Task { try await endpoint.invoke("wait", timeout: 30) }
                try await wait {
                    FileManager.default.fileExists(
                        atPath: data.appendingPathComponent("peer.ready").path)
                }
                stage = "shutdown"
                let stoppedAt = ContinuousClock.now
                if mode == "crash" {
                    kill(pid, SIGKILL)
                } else {
                    try await worker.stop()
                }
                do {
                    _ = try await pending.value
                    throw HostWorkerError.rejected
                } catch is ExtensionPeerError {} catch is CancellationError {}
                guard ContinuousClock.now - stoppedAt < .seconds(5) else {
                    throw HostWorkerError.timedOut
                }
                if mode == "asyncStop" {
                    guard
                        try Data(contentsOf: data.appendingPathComponent("finalized"))
                            == Data("finalized".utf8)
                    else { throw HostWorkerError.rejected }
                } else if mode == "asyncHang" {
                    guard
                        !FileManager.default.fileExists(
                            atPath: data.appendingPathComponent("finalized").path)
                    else { throw HostWorkerError.rejected }
                }
                do {
                    _ = try await endpoint.invoke("echo", timeout: 1)
                    throw HostWorkerError.rejected
                } catch is ExtensionPeerError {}
                stage = "process cleanup"
                try await wait {
                    [pid, parent, child].allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
                }
                guard sharedState.values(for: package.id).isEmpty else {
                    throw HostWorkerError.rejected
                }
                try errorOutput.close()
                guard
                    !(try String(contentsOf: log, encoding: .utf8)).contains(
                        "is implemented in both")
                else {
                    throw HostWorkerError.invalidResponse
                }
                print(
                    "{\"mode\":\"\(mode)\",\"sameAppExecutable\":true,\"nestedHelperRole\":true,\"carrierMetadata\":true,\"signatureVerified\":true,\"frozenExecutableProvenance\":true,\"binaryInput\":true,\"argumentsAndEnvironment\":true,\"peerCommands\":true,\"commandCancellation\":true,\"boundedShutdown\":true,\"isolatedSupportTypes\":true,\"remainingProcesses\":0}"
                )
            } catch {
                try? await worker.stop()
                try? errorOutput.close()
                let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                throw NSError(
                    domain: "ExtensionFixture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Worker \(mode) failed during \(stage): \(error). \(detail)"
                    ])

            }
        }
    }

    private static func verifyCarrier(
        directory: URL, store: ExtensionPackageStore,
        package: ExtensionPackage, identifier: String, executable: URL
    ) throws -> ExtensionUICarrier {
        let carrier = try ExtensionUICarrier(
            payload: directory, package: package, expectedHostIdentifier: identifier)
        try carrier.verifyDevelopment()
        let role = store.roleBundle(for: package, role: .helper)
        let expectedRole = directory.appendingPathComponent(
            "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/keepAwake/helper.bundle"
        )
        guard role == expectedRole,
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("helper.bundle").path),
            let bundle = Bundle(url: role),
            bundle.bundleIdentifier == "com.pulkit.edith.extensions.keepAwake.helper",
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == package.version,
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String
                == HostContract.compatibility,
            carrier.hostExecutablePath == (try canonicalPath(executable)),
            carrier.executableProvenance
                == SHA256.hash(data: try Data(contentsOf: executable)).map({
                    String(format: "%02x", $0)
                }).joined()
        else {
            throw NSError(
                domain: "ExtensionFixture", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Nested role mismatch: role=\(role), expected=\(expectedRole), identifier=\(Bundle(url: role)?.bundleIdentifier ?? "missing"), ABI=\(Bundle(url: role)?.object(forInfoDictionaryKey: "EdithHostABI") ?? "missing"), hostPath=\(carrier.hostExecutablePath), expectedHost=\(executable.resolvingSymlinksInPath().path), provenance=\(carrier.executableProvenance)"
                ])
        }
        try ExtensionCodeSignature.verifyDevelopment(role)
        return carrier
    }

    private static func canonicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw HostWorkerError.rejected }
        defer { free(path) }
        return String(cString: path)
    }

    private static func executablePath(_ pid: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else {
            throw HostWorkerError.rejected
        }
        return try canonicalPath(
            URL(
                fileURLWithPath: String(
                    decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                    as: UTF8.self)))
    }

    @MainActor private static func verifyCommands(_ endpoint: ExtensionPeerEndpoint, data: URL)
        async throws
    {

        var stage = "large echo"
        do {
            let payload = Data((0..<(1_024 * 1_024)).map { UInt8(truncatingIfNeeded: $0) })
            guard try await endpoint.invoke("echo", payload: payload) == payload else {
                throw HostWorkerError.rejected
            }
            let wrong = try ExtensionPeerEndpoint(
                namespace: UUID().uuidString, owner: "keepAwake",
                directory: data.appendingPathComponent("isolated"))
            do {
                _ = try await wrong.invoke("echo", timeout: 1)
                throw HostWorkerError.rejected
            } catch is ExtensionPeerError {}
            do {
                _ = try await endpoint.invoke("unknown")
                throw HostWorkerError.rejected
            } catch is ExtensionPeerError {}

            stage = "busy UI"
            let blocked = Task { try await endpoint.invoke("blockUI", timeout: 5) }
            try await wait {
                FileManager.default.fileExists(
                    atPath: data.appendingPathComponent("ui-block.ready").path)
            }
            guard
                try await endpoint.invoke("echo", payload: Data("queued".utf8), timeout: 3)
                    == Data("queued".utf8), try await blocked.value == Data("ready".utf8)
            else { throw HostWorkerError.rejected }
            stage = "cancellation"
            let marker = data.appendingPathComponent("peer.ready")
            let cancelled = Task { try await endpoint.invoke("wait") }
            try await wait { FileManager.default.fileExists(atPath: marker.path) }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                throw HostWorkerError.rejected
            } catch is CancellationError {}
            try await wait { !FileManager.default.fileExists(atPath: marker.path) }
            stage = "deadline"
            do {
                _ = try await endpoint.invoke("wait", timeout: 0.3)
                throw HostWorkerError.rejected
            } catch is ExtensionPeerError {}
            try await wait { !FileManager.default.fileExists(atPath: marker.path) }

            stage = "echo after cancellation"
            guard try await endpoint.invoke("echo", payload: payload) == payload else {
                throw HostWorkerError.rejected
            }
        } catch {
            throw NSError(
                domain: "ExtensionCommands", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(stage): \(error)"])
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
