import Foundation
import Testing
@testable import ExtensionMarketplace

@Suite(.serialized) @MainActor struct ExtensionBundleRuntimeTests {
    @Test func aRealBundleStartsStopsAndWaitsForRestartToApplyItsUpdate() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = fixture.directory.appendingPathComponent("release")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "bun", "scripts/build-extension-package.mjs", "keepAwake", "--development",
        ]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["EXTENSION_OUTPUT"] = output.path
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        process.environment = environment
        let log = fixture.directory.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        #expect(process.terminationStatus == 0, "Native extension fixture must build successfully")
        let package = try JSONDecoder().decode(
            ExtensionPackage.self,
            from: Data(contentsOf: output.appendingPathComponent("keepAwake.json")))
        let archive = output.appendingPathComponent("keepAwake.zip")
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "pulkitxm/edith")
        let runtime = ExtensionBundleRuntime(
            store: fixture.store, role: .helper, hostABI: package.hostABI,
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
        let suite = "marketplace-runtime-\(UUID().uuidString)"
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
        try await runtime.prepareDisableAll()
        try runtime.stopAll()
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
        defaults.set(true, forKey: "keepAwakeEnabled")
        defaults.set(false, forKey: "preventSleep")
        try runtime.start(id: package.id, context: ["defaultsSuite": suite])
        #expect(try runtime.snapshot(id: package.id)?.active == true)
        #expect(
            try runtime.response(id: package.id, operation: "status")["running"] as? Bool == true)
        try runtime.synchronize(id: package.id, context: [:])
        try runtime.stop(id: package.id)
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
        try runtime.start(id: package.id, context: ["defaultsSuite": suite])
        #expect(try runtime.snapshot(id: package.id)?.version == package.version)
        try runtime.stopAll()
        let privileged = fixture.store.roleBundle(for: package, role: .privileged)
        try FileManager.default.createDirectory(at: privileged, withIntermediateDirectories: true)
        let privilegedRuntime = ExtensionBundleRuntime(
            store: fixture.store, role: .helper, hostABI: package.hostABI,
            packageVersion: package.version,
            verify: ExtensionCodeSignature.verifyDevelopment)
        #expect(throws: MarketplaceError.invalidBundle) {
            try privilegedRuntime.start(id: package.id, context: ["defaultsSuite": suite])
        }
        #expect(try privilegedRuntime.snapshot(id: package.id) == nil)
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
            minimumSystemVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1,
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
