import Darwin
import Foundation
import Testing
@testable import ExtensionMarketplace

@Suite(.serialized) @MainActor struct ExtensionBundleRuntimeTests {
    @Test func aSignedBundleRecoveryLoadsReadOnlyAndPinsItsVersionUntilReload() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = fixture.directory.appendingPathComponent("release")
        let environment = ProcessInfo.processInfo.environment
        let host = MarketplaceRuntimeBuildFixture.containingHost(
            repositoryRoot: repositoryRoot, environment: environment)
        if environment["EXTENSION_CONTAINING_HOST_APP"] == nil {
            do {
                try MarketplaceRuntimeBuildFixture.run(
                    ["/usr/bin/codesign", "--verify", "--deep", "--strict", host.path],
                    repositoryRoot: repositoryRoot, directory: fixture.directory,
                    environment: environment, stage: "host-signature")
            } catch {
                try MarketplaceRuntimeBuildFixture.run(
                    ["/usr/bin/env", "bun", "scripts/build-minimal-host.mjs"],
                    repositoryRoot: repositoryRoot, directory: fixture.directory,
                    environment: environment, stage: "host-build")
            }
        }
        var buildEnvironment = environment
        buildEnvironment["EXTENSION_OUTPUT"] = output.path
        buildEnvironment["EXTENSION_CONTAINING_HOST_APP"] = host.path
        try MarketplaceRuntimeBuildFixture.run(
            [
                "/usr/bin/env", "bun", "scripts/build-extension-package.mjs", "keepAwake",
                "--development",
            ],
            repositoryRoot: repositoryRoot, directory: fixture.directory,
            environment: buildEnvironment, stage: "package-build")
        let package = try JSONDecoder().decode(
            ExtensionPackage.self,
            from: Data(contentsOf: output.appendingPathComponent("keepAwake.json")))
        let archive = output.appendingPathComponent("keepAwake.zip")
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "pulkitxm/edith")
        let kit = host.appendingPathComponent("Contents/Frameworks/libEdithExtensionKit.dylib")
        try #require(dlopen(kit.path, RTLD_NOW | RTLD_GLOBAL) != nil)
        let suite = "marketplace-runtime-\(UUID().uuidString)"
        let runtime = ExtensionBundleRuntime(
            store: fixture.store, role: .helper, hostABI: package.hostABI,
            environment: ["EDITH_SHARED_DEFAULTS_SUITE": suite, "EDITH_EXTENSION_ID": package.id],
            verify: { bundle in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                process.arguments = ["--verify", "--strict", bundle.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw MarketplaceError.invalidSignature
                }
            })
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "keepAwakeEnabled")
        defaults.set(true, forKey: "preventSleep")
        try runtime.start(id: package.id, context: ["defaultsSuite": suite, "recoveryOnly": true])
        #expect(try runtime.snapshot(id: package.id)?.active == false)
        #expect(
            try runtime.response(id: package.id, operation: "status")["running"] as? Bool == false)
        #expect(!defaults.bool(forKey: "keepAwakeEnabled"))
        #expect(defaults.bool(forKey: "preventSleep"))
        let selectedDirectory = fixture.store.payloadDirectory(for: package)
            .deletingLastPathComponent()
        let ui = try ExtensionBundleRuntime(
            readOnlyPackage: package, directory: selectedDirectory, role: .helper,
            hostABI: package.hostABI, verify: ExtensionCodeSignature.verifyDevelopment)
        #expect(throws: MarketplaceError.invalidBundle) {
            try ui.start(id: package.id, context: ["defaultsSuite": suite])
        }
        let description = try ui.response(id: package.id, operation: "describe")
        #expect(description["id"] as? String == package.id)
        #expect(try ui.snapshot(id: package.id)?.active == false)
        #expect(throws: MarketplaceError.invalidBundle) {
            try ui.response(id: package.id, operation: "start", context: ["defaultsSuite": suite])
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: selectedDirectory.appendingPathComponent(".leases").path))
        #expect(!defaults.bool(forKey: "keepAwakeEnabled"))
        try runtime.start(id: package.id, context: ["defaultsSuite": suite, "recoveryOnly": true])
        #expect(try runtime.snapshot(id: package.id)?.active == false)
        #expect(
            try runtime.response(id: package.id, operation: "status")["running"] as? Bool == false)
        try runtime.synchronize(id: package.id, context: [:])
        #expect(!defaults.bool(forKey: "keepAwakeEnabled"))
        #expect(defaults.bool(forKey: "preventSleep"))
        #expect(try runtime.snapshot(id: package.id)?.active == false)
        #expect(
            try runtime.response(id: package.id, operation: "status")["running"] as? Bool == false)
        #expect(throws: MarketplaceError.packageBusy) { try fixture.store.remove(id: package.id) }
        let next = ExtensionPackage(
            id: package.id, version: "1.1.0", hostABI: package.hostABI,
            downloadURL: package.downloadURL, sha256: package.sha256,
            downloadBytes: package.downloadBytes, installedBytes: package.installedBytes)
        try fixture.store.commit([package, next])
        #expect(try runtime.snapshot(id: package.id)?.restartRequired == true)
        try runtime.start(id: package.id, context: ["defaultsSuite": suite, "recoveryOnly": true])
        #expect(try runtime.snapshot(id: package.id)?.version == package.version)
        #expect(try runtime.snapshot(id: package.id)?.active == false)
        #expect(!defaults.bool(forKey: "keepAwakeEnabled"))
        #expect(defaults.bool(forKey: "preventSleep"))
        #expect(!runtime.supportsCommands(id: package.id))
        try await runtime.suspendCommandsAll()
        #expect(
            try runtime.response(id: package.id, operation: "synchronize")["ok"] as? Bool == false)
        try await runtime.prepareDisableAll()
        #expect(!defaults.bool(forKey: "preventSleep"))
        try await runtime.prepareToStopAll()
        try runtime.stopAll()
        try await runtime.prepareToStopAll()
        try runtime.stopAll()
        #expect(!runtime.supportsCommands(id: package.id))
    }

    @Test func aFailedStartRetainsOwnershipUntilAsyncTeardownFinishes() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let package = ExtensionPackage(
            id: "failedStart", version: "1.0.0", hostABI: "synthetic-abi",
            downloadURL: URL(string: "https://synthetic.invalid/failedStart.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        let role = fixture.store.roleBundle(for: package, role: .app)
        let contents = role.appendingPathComponent("Contents")
        let binaries = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let executable = binaries.appendingPathComponent("FailedStart")
        let source = fixture.directory.appendingPathComponent("FailedStart.swift")
        try """
        import Foundation
        import EdithExtensionCore
        @MainActor final class FailedStartService: ExtensionService {
            var requiresDefaultsSuite: Bool { false }
            private var directory: URL?
            private var starts = 0
            private var teardowns = 0
            func start(_ context: ExtensionHostContext) -> Bool {
                guard let path = context.dataDirectory else { return false }
                let directory = URL(fileURLWithPath: path)
                self.directory = directory
                starts += 1
                try? Data(String(starts).utf8).write(to: directory.appendingPathComponent("starts"))
                return false
            }
            func teardown() async {
                teardowns += 1
                try? await Task.sleep(for: .milliseconds(50))
                guard let directory else { return }
                try? Data(String(teardowns).utf8).write(to: directory.appendingPathComponent("teardowns"))
            }
        }
        private final class FailedStartBundleAnchor {}
        @_cdecl("edith_extension_create")
        public func createFailedStart() -> UnsafeMutableRawPointer? {
            MainActor.assumeIsolated {
                Unmanaged.passRetained(ExtensionServiceRuntime(
                    id: "failedStart", role: "app", bundle: Bundle(for: FailedStartBundleAnchor.self)
                ) { _ in FailedStartService() }).toOpaque()
            }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let information: [String: Any] = [
            "CFBundleIdentifier": "com.pulkit.edith.extensions.failedStart.app",
            "CFBundleExecutable": "FailedStart", "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": package.version, "EdithHostABI": package.hostABI,
            "EdithRuntimeAPIVersion": 1,
        ]
        try PropertyListSerialization.data(
            fromPropertyList: information, format: .xml, options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        try JSONEncoder().encode(ExtensionPayloadManifest(package: package)).write(
            to: fixture.store.payloadDirectory(for: package).appendingPathComponent("package.json"))
        let products = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/arm64-apple-macosx/debug")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "swiftc", "-emit-library", "-module-name", "FailedStartFixture",
            "-I", products.appendingPathComponent("Modules").path,
            "-L", products.path, "-lEdithExtensionKit",
            "-Xlinker", "-rpath", "-Xlinker", products.path,
            source.path, "-o", executable.path,
        ]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", role.path]
        try signer.run()
        signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        try fixture.store.commit([package])
        for stopBeforeWait in [false, true] {
            let runtime = ExtensionBundleRuntime(
                store: fixture.store, role: .app, hostABI: package.hostABI,
                verify: ExtensionCodeSignature.verifyDevelopment)
            let dataDirectory = fixture.directory.appendingPathComponent(
                "synthetic-data-\(stopBeforeWait)")
            try FileManager.default.createDirectory(
                at: dataDirectory, withIntermediateDirectories: true)
            let starts = dataDirectory.appendingPathComponent("starts")
            let teardowns = dataDirectory.appendingPathComponent("teardowns")
            let context: NSDictionary = ["dataDirectory": dataDirectory.path]
            #expect(throws: (any Error).self) {
                try runtime.start(id: package.id, context: context)
            }
            #expect(try String(contentsOf: starts, encoding: .utf8) == "1")
            #expect(!FileManager.default.fileExists(atPath: teardowns.path))
            #expect(try runtime.snapshot(id: package.id)?.active == false)
            #expect(!runtime.supportsCommands(id: package.id))
            if stopBeforeWait { try runtime.stopAll() }
            try await runtime.prepareToStopAll()
            #expect(try String(contentsOf: teardowns, encoding: .utf8) == "1")
            try runtime.stopAll()
            try runtime.stopAll()
            try await runtime.prepareToStopAll()
            #expect(throws: (any Error).self) {
                try runtime.start(id: package.id, context: context)
            }
            #expect(try String(contentsOf: starts, encoding: .utf8) == "1")
            #expect(try String(contentsOf: teardowns, encoding: .utf8) == "1")
        }
    }

    @Test func anUninstalledExtensionCannotStart() {
        let runtime = ExtensionBundleRuntime(
            store: ExtensionPackageStore(
                root: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)), role: .helper, hostABI: "runtime-1", verify: { _ in })
        #expect(throws: MarketplaceError.packageNotInstalled) {
            try runtime.start(id: "keepAwake", context: [:])
        }
    }

    @Test func aPinnedFutureSystemPackageIsRejectedBeforeVerificationOrLoading() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let package = ExtensionPackage(
            id: "keepAwake", version: "1.0.0", hostABI: "runtime-1",
            minimumSystemVersion: .init(
                major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1),
            downloadURL: URL(
                string: "https://github.com/example/app/releases/download/fixture/keepAwake.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        try FileManager.default.createDirectory(
            at: fixture.store.root, withIntermediateDirectories: true)
        try fixture.store.commit([package])
        var verified = false
        let runtime = ExtensionBundleRuntime(
            store: fixture.store, role: .helper, hostABI: package.hostABI,
            packageVersion: package.version, verify: { _ in verified = true })
        #expect(throws: MarketplaceError.packageNotInstalled) {
            try runtime.start(id: package.id, context: [:])
        }
        #expect(!verified)
    }
}

struct MarketplaceRuntimeBuildFixture {
    static func marker(stage: String, status: String, pid: Int32? = nil, exit: Int32? = nil)
        -> String?
    {
        guard ["host-signature", "host-build", "package-build", "failed-build"].contains(stage),
            ["started", "running", "exited", "launch-failed"].contains(status),
            pid == nil || pid! > 1
        else { return nil }
        var value = "[marketplace-fixture] stage=\(stage) status=\(status)"
        if let pid { value += " pid=\(pid)" }
        if let exit { value += " exit=\(exit)" }
        return value + "\n"
    }

    static func report(stage: String, status: String, pid: Int32? = nil, exit: Int32? = nil) {
        guard let value = marker(stage: stage, status: status, pid: pid, exit: exit) else { return }
        FileHandle.standardError.write(Data(value.utf8))
    }

    struct Failure: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        let log: URL
        let output: String

        var description: String {
            "Fixture command failed (\(status)): \(arguments.joined(separator: " "))\nLog: \(log.path)\n\(output)"
        }
    }

    static func containingHost(repositoryRoot: URL, environment: [String: String]) -> URL {
        if let path = environment["EXTENSION_CONTAINING_HOST_APP"] {
            return URL(fileURLWithPath: path, relativeTo: repositoryRoot).absoluteURL
        }
        return repositoryRoot.appendingPathComponent("local/minimal-host/Edith.app")
    }

    static func run(
        _ arguments: [String], repositoryRoot: URL, directory: URL,
        environment: [String: String], stage: String
    ) throws {
        let log = directory.appendingPathComponent(stage + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = repositoryRoot
        var environment = environment
        environment["DEVELOPER_DIR"] =
            environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        environment["EXTENSION_SWIFT_JOBS"] = "1"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        report(stage: stage, status: "started")
        do {
            try process.run()
        } catch {
            report(stage: stage, status: "launch-failed")
            throw error
        }
        report(stage: stage, status: "running", pid: process.processIdentifier)
        process.waitUntilExit()
        report(
            stage: stage, status: "exited", pid: process.processIdentifier,
            exit: process.terminationStatus)
        try handle.synchronize()
        guard process.terminationStatus == 0 else {
            throw Failure(
                arguments: arguments, status: process.terminationStatus, log: log,
                output: String(decoding: try Data(contentsOf: log), as: UTF8.self))
        }
    }
}

@Suite struct MarketplaceRuntimeBuildFixtureTests {
    @Test func fixtureCommandsRetainTheSelectedDeveloperAndDefaultOnlyWhenAbsent() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        for selected in ["/synthetic/SelectedXcode.app/Contents/Developer", nil] {
            let environment = selected.map { ["DEVELOPER_DIR": $0] } ?? [:]
            try MarketplaceRuntimeBuildFixture.run(
                ["/usr/bin/printenv", "DEVELOPER_DIR"], repositoryRoot: fixture.directory,
                directory: fixture.directory, environment: environment, stage: "failed-build")
            let output = try String(
                contentsOf: fixture.directory.appendingPathComponent("failed-build.log"),
                encoding: .utf8)
            #expect(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    == selected ?? "/Applications/Xcode.app/Contents/Developer")
        }
    }

    @Test func stageMarkersAreClosedAndNeverIncludeArgumentsOrLogPaths() {
        #expect(
            MarketplaceRuntimeBuildFixture.marker(stage: "host-build", status: "started")
                == "[marketplace-fixture] stage=host-build status=started\n")
        #expect(
            MarketplaceRuntimeBuildFixture.marker(
                stage: "package-build", status: "exited", pid: 123, exit: 3)
                == "[marketplace-fixture] stage=package-build status=exited pid=123 exit=3\n")
        #expect(
            MarketplaceRuntimeBuildFixture.marker(stage: "/private/input", status: "started") == nil
        )
        #expect(MarketplaceRuntimeBuildFixture.marker(stage: "host-build", status: "secret") == nil)
        #expect(
            MarketplaceRuntimeBuildFixture.marker(stage: "host-build", status: "running", pid: 1)
                == nil)
    }

    @Test func anExplicitFrozenHostIsNeverReplacedByTheLocalDefault() {
        let root = URL(fileURLWithPath: "/synthetic/repository")
        #expect(
            MarketplaceRuntimeBuildFixture.containingHost(
                repositoryRoot: root,
                environment: ["EXTENSION_CONTAINING_HOST_APP": "/synthetic/frozen/Edith.app"])
                == URL(fileURLWithPath: "/synthetic/frozen/Edith.app"))
        #expect(
            MarketplaceRuntimeBuildFixture.containingHost(repositoryRoot: root, environment: [:])
                == root.appendingPathComponent("local/minimal-host/Edith.app"))
    }

    @Test func aFailedCommandThrowsItsCapturedDiagnosticBeforeReadingPackageMetadata() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        do {
            try MarketplaceRuntimeBuildFixture.run(
                ["/usr/bin/env", "--invalid-fixture-option"], repositoryRoot: fixture.directory,
                directory: fixture.directory, environment: [:], stage: "failed-build")
            Issue.record("A failed command must throw")
        } catch let failure as MarketplaceRuntimeBuildFixture.Failure {
            #expect(failure.status != 0)
            #expect(!failure.output.isEmpty)
            #expect(failure.description.contains("--invalid-fixture-option"))
            #expect(failure.description.hasSuffix(failure.output))
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directory.appendingPathComponent("keepAwake.json").path))
    }

    @Test func theHostMarketplaceGateRunsTheMarketplaceRuntime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let makefile = try String(
            contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        let target = try #require(
            makefile.components(separatedBy: "ci-marketplace-host: ci-host host\n").last)
        let commands = try #require(target.components(separatedBy: "\n\n").first)
        #expect(commands.contains("$(MAKE) ci-marketplace-runtime"))
    }

    @Test func aBuildFailureRetainsTheCompleteCommandAndDiagnostic() {
        let output = "synthetic compile failed\nmissing scoped module\n"
        let failure = MarketplaceRuntimeBuildFixture.Failure(
            arguments: ["bun", "scripts/build-extension-package.mjs", "keepAwake"], status: 3,
            log: URL(fileURLWithPath: "/synthetic/package-build.log"), output: output)
        #expect(failure.description.contains("Fixture command failed (3)"))
        #expect(failure.description.contains("bun scripts/build-extension-package.mjs keepAwake"))
        #expect(failure.description.contains("/synthetic/package-build.log"))
        #expect(failure.description.hasSuffix(output))
    }
}
