import EdithHostCore
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostRequirementsCLIAdapterTests {
    @Test func productionFactoryInspectsAll39AbsentAndDisabledPackagesWithoutEffects() async throws
    {
        let fixture = try RequirementsConsumerFixture()
        defer { fixture.clean() }
        let backend = try HostRequirementsCLIAdapter.make(
            marketplace: fixture.marketplace, permissions: fixture.permissions,
            hooks: fixture.hooks, toolDirectories: [],
            systemVersion: .init(majorVersion: 14, minorVersion: 3, patchVersion: 0))
        #expect(backend.entries().map(\.id) == HostExtensionRequirementCatalog.entries.map(\.id))
        let before = try fixture.files()
        let preferences = fixture.defaults.persistentDomain(forName: fixture.identity.defaultsSuite)
        for entry in backend.entries() {
            let report = try await backend.inspect(entry.id, "status")
            #expect(!report.verified && report.state.phase == .disabled)
            #expect(report.checks.first { $0.id == "package" }?.runtimePhase == .uninstalled)
            let setup = try await backend.setup(entry.id, true, true)
            #expect(setup.dryRun && !setup.changed && setup.installedTools.isEmpty)
            #expect(setup.report.checks.contains { $0.id == "setup.preview" })
            #expect(
                setup.report.checks.contains { $0.id == "owner.inspection" && $0.status == .failed }
            )
        }
        #expect(try fixture.files() == before)
        #expect(
            NSDictionary(
                dictionary: fixture.defaults.persistentDomain(
                    forName: fixture.identity.defaultsSuite) ?? [:])
                == NSDictionary(dictionary: preferences ?? [:]))
        let packages = backend.entries().map { fixture.package($0.id) }
        try fixture.store.commit(packages)
        let installed = try fixture.files()
        for entry in backend.entries() {
            let report = try await backend.inspect(entry.id, "doctor")
            #expect(!report.verified && report.state.phase == .disabled)
            #expect(report.checks.first { $0.id == "package" }?.status == .failed)
        }
        #expect(try fixture.files() == installed)
        #expect(
            fixture.starts == 0 && fixture.permissionReads == 0 && fixture.permissionRequests == 0)
        #expect(await fixture.calls.count == 0)
    }

    @Test func capturedPermissionMissingToolsAndOriginalPlatformGatesArePreserved() async throws {
        let fixture = try RequirementsConsumerFixture()
        defer { fixture.clean() }
        fixture.captured = [.calendar: true, .screenRecording: false]
        await fixture.permissions.refresh()
        let backend = try HostRequirementsCLIAdapter.make(
            marketplace: fixture.marketplace, permissions: fixture.permissions,
            hooks: fixture.hooks, toolDirectories: [],
            systemVersion: .init(majorVersion: 14, minorVersion: 3, patchVersion: 0))
        let calendar = try await backend.inspect("calendar", "verify")
        #expect(calendar.checks.first { $0.id == "permission.calendar" }?.status == .passed)
        let focus = try await backend.inspect("focusDim", "verify")
        #expect(focus.checks.first { $0.id == "permission.screenRecording" }?.status == .failed)
        let keys = try await backend.inspect("keystrokeHighlight", "verify")
        #expect(
            keys.checks.first { $0.id == "permission.inputMonitoring" }?.runtimePhase == .loading)
        let audio = try await backend.inspect("audioMixer", "verify")
        #expect(
            audio.checks.first { $0.id == "capability.applicationAudio" }?.runtimePhase
                == .unsupported)
        let recorder = try await backend.inspect("timeLapse", "verify")
        #expect(
            recorder.checks.first { $0.id == "capability.screenTimeLapse" }?.runtimePhase
                == .unsupported)
        let downloads = try await backend.inspect("downloads", "verify")
        #expect(
            downloads.checks.filter { $0.id.hasPrefix("tool.") && $0.status == .failed }.count == 3)
        let herdr = try await backend.inspect("herdr", "verify")
        #expect(
            herdr.checks.last?.detail.contains(
                "Actual Herdr host inventory inspection is unavailable") == true)
        #expect(
            fixture.permissionReads == 1 && fixture.permissionRequests == 0 && fixture.starts == 0)
        #expect(await fixture.calls.count == 0)
    }

    @Test func actualSignatureCompatibilityAndPendingRemovalPathsRemainReadonly() async throws {
        let fixture = try RequirementsConsumerFixture()
        defer { fixture.clean() }
        let backend = try fixture.liveBackend()
        try fixture.store.commit([fixture.package("calendar", abi: "wrong-abi")])
        #expect(
            try await backend.inspect("calendar", "verify").checks.first { $0.id == "package" }?
                .runtimePhase == .unsupported)
        try fixture.store.commit([fixture.package("calendar", architecture: "invalid")])
        #expect(
            try await backend.inspect("calendar", "verify").checks.first { $0.id == "package" }?
                .runtimePhase == .error)
        try fixture.store.commit([fixture.package("calendar")])
        let before = try fixture.files()
        #expect(
            try await backend.inspect("calendar", "verify").checks.first { $0.id == "package" }?
                .runtimePhase == .error)
        #expect(try fixture.files() == before)
        fixture.defaults.set(["calendar"], forKey: "enabledExtensions")
        fixture.marketplace.sessions.requestDisable(ids: ["calendar"])
        let pending = try fixture.files()
        let disabled = try await backend.inspect("calendar", "verify")
        #expect(
            disabled.checks.first { $0.id == "package" }?.detail.contains("pending disable") == true
        )
        #expect(try fixture.files() == pending)
        await #expect(throws: HostCLIError.self) {
            try await backend.setup("calendar", false, false)
        }
        fixture.defaults.set([], forKey: "enabledExtensions")
        try JSONEncoder().encode(["downloads"]).write(
            to: fixture.store.root.appendingPathComponent("pending-removals.json"))
        let removal = try await backend.inspect("downloads", "verify")
        #expect(removal.checks.first { $0.id == "package" }?.status == .failed)
        #expect(fixture.starts == 0 && fixture.permissionRequests == 0)
        #expect(await fixture.calls.count == 0)
    }

    @Test func readonlyInspectionUsesOnlyCurrentOwnerAndDiscardsStaleVersionPIDOrDisable()
        async throws
    {
        let fixture = try RequirementsOwnerFixture()
        defer { fixture.clean() }
        let backend = HostRequirementsCLIAdapter.make(environment: fixture.environment())
        #expect(try await backend.inspect("calendar", "verify").verified)
        #expect(fixture.inspections == 1)
        for mutation in ["version", "pid", "disable", "removal"] {
            fixture.reset(); fixture.change = mutation
            let report = try await backend.inspect("calendar", "doctor")
            #expect(!report.verified)
            #expect(report.checks.last?.detail.contains("changed") == true)
            #expect(fixture.inspections == 1)
        }
        fixture.reset(); fixture.activation = fixture.state(active: false)
        #expect(try await backend.inspect("calendar", "verify").verified == false)
        #expect(fixture.inspections == 0)
        fixture.reset(); fixture.activation = fixture.state(version: "2.0.0")
        #expect(try await backend.inspect("calendar", "verify").verified == false)
        #expect(fixture.inspections == 0)
    }

    @Test func setupDelegatesOnlyAlreadyActiveOwnerAndRejectsLateReplacement() async throws {
        let fixture = try RequirementsOwnerFixture()
        defer { fixture.clean() }
        let backend = HostRequirementsCLIAdapter.make(environment: fixture.environment())
        let before = try fixture.files()
        let preview = try await backend.setup("calendar", true, true)
        #expect(preview.dryRun && !preview.changed && fixture.setups == 0)
        #expect(try fixture.files() == before)
        let setup = try await backend.setup("calendar", false, false)
        #expect(!setup.dryRun && fixture.setups == 1)
        for mutation in ["version", "pid", "disable", "removal"] {
            fixture.reset(); fixture.change = mutation
            await #expect(throws: HostCLIError.self) {
                try await backend.setup("calendar", false, false)
            }
            #expect(fixture.setups == 1)
        }
        fixture.reset(); fixture.activation = fixture.state(active: false)
        await #expect(throws: HostCLIError.self) {
            try await backend.setup("calendar", false, false)
        }
        #expect(fixture.setups == 0)
        #expect(try fixture.files() == before)
    }

    @Test func cancellationWrongOwnerAndUnknownIdentityDoNotProduceHealthyReplies() async throws {
        let fixture = try RequirementsOwnerFixture()
        defer { fixture.clean() }
        let backend = HostRequirementsCLIAdapter.make(environment: fixture.environment())
        fixture.cancel = true
        await #expect(throws: CancellationError.self) {
            try await backend.inspect("calendar", "verify")
        }
        await #expect(throws: CancellationError.self) {
            try await backend.setup("calendar", false, false)
        }
        fixture.reset(); fixture.wrongOwner = true
        #expect(try await backend.inspect("calendar", "verify").verified == false)
        await #expect(throws: (any Error).self) {
            try await backend.inspect("not-an-extension", "verify")
        }
        fixture.reset(); fixture.cancelTool = true
        await #expect(throws: CancellationError.self) {
            try await backend.setup("downloads", true, true)
        }
    }

    @Test func actualCLIReportsUnhealthyExitZeroAndDryRunNeverStartsOwner() async throws {
        let fixture = try RequirementsConsumerFixture()
        defer { fixture.clean() }
        let cli = HostCoreReadinessCLI(backend: try fixture.liveBackend())
        let before = try fixture.files()
        for command in ["status", "verify", "doctor"] {
            let reply = try await cli.execute([command, "downloads", "--json"])
            #expect(reply.exitCode == 0)
            let value = try JSONDecoder().decode(HostCLIJSON.self, from: Data(reply.stdout.utf8))
            #expect(value.object?["verified"] == .bool(false))
        }
        let preview = try await cli.execute([
            "setup", "downloads", "--dry-run", "--install-tools", "--json",
        ])
        #expect(preview.exitCode == 0)
        #expect(preview.stdout.contains("Choose an existing, writable download folder."))
        #expect(try fixture.files() == before)
        #expect(await fixture.calls.count == 0)
        #expect(
            fixture.starts == 0 && fixture.permissionReads == 0 && fixture.permissionRequests == 0)
    }

    @Test func expectedRolesMatchCurrent39ManifestAndExplicitPathsAreValidated() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let rows = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent("Extensions/manifest.json")))
                as? [[String: Any]])
        #expect(rows.count == 39 && HostRequirementsCLIAdapter.packagedRoles.count == 39)
        for row in rows {
            let id = try #require(row["id"] as? String)
            let roles = try #require(row["roles"] as? [String: Any])
            #expect(
                HostRequirementsCLIAdapter.packagedRoles[id]
                    == Set(roles.keys).subtracting(["cameraCarrier", "cameraProvider"]))
        }
        let fixture = try RequirementsConsumerFixture()
        defer { fixture.clean() }
        #expect(throws: HostCLIError.self) {
            try HostRequirementsCLIAdapter.make(
                marketplace: fixture.marketplace, permissions: fixture.permissions,
                hooks: fixture.hooks, toolDirectories: [URL(string: "https://synthetic.invalid")!])
        }
    }
}

private actor RequirementsCalls {
    private(set) var count = 0
    func invoked() { count += 1 }
}

@MainActor private final class RequirementsConsumerFixture {
    let root: URL
    let identity: HostIdentity
    let defaults: UserDefaults
    let store: ExtensionPackageStore
    let calls = RequirementsCalls()
    var starts = 0; var permissionReads = 0; var permissionRequests = 0
    var captured: [HostPermission: Bool] = [:]
    var marketplace: HostMarketplace!
    var permissions: HostPermissions!
    var hooks: HostCoreOwnerHooks {
        HostCoreOwnerHooks(invoke: { [calls] _ in
            await calls.invoked(); throw HostCLIError.unavailable
        })
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "requirements-consumer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.requirements-" + UUID().uuidString,
            supportDirectory: root)
        defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
        store = .init(root: identity.root.appendingPathComponent("Extensions"))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let sessions = HostExtensionSessions(defaults: defaults) { _ in
            self.starts += 1; throw HostWorkerError.rejected
        }
        let client = ExtensionCatalogClient(
            url: URL(string: "https://synthetic.invalid/catalog")!, publicKey: Data(),
            repository: "synthetic/fixture",
            cache: root.appendingPathComponent("catalog.json"),
            fetch: { [calls] _ in
                await calls.invoked(); throw MarketplaceError.downloadFailed
            })
        let installer = ExtensionPackageInstaller(
            store: store,
            download: { [calls] _, _ in
                await calls.invoked(); throw MarketplaceError.downloadFailed
            }, verify: { _ in throw MarketplaceError.invalidSignature })
        marketplace = try HostMarketplace(
            identity: identity,
            entries: HostExtensionRequirementCatalog.entries.map {
                .init(id: $0.id, title: $0.title, symbolName: "circle", category: "Synthetic")
            },
            store: store, catalogClient: client, installer: installer, sessions: sessions)
        permissions = HostPermissions(
            environment: .init(
                read: {
                    self.permissionReads += 1; return self.captured
                },
                request: { _ in self.permissionRequests += 1 },
                openSettings: { _ in
                    self.permissionRequests += 1; return false
                }))
    }
    func package(
        _ id: String, abi: String = HostContract.compatibility, architecture: String = "arm64"
    ) -> ExtensionPackage {
        .init(
            id: id, version: "1.0.0", hostABI: abi, architecture: architecture,
            downloadURL: URL(
                string: "https://github.com/synthetic/fixture/releases/download/1.0.0/\(id).zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1024)
    }
    func liveBackend() throws -> HostCoreReadinessCLIBackend {
        try HostRequirementsCLIAdapter.make(
            marketplace: marketplace, permissions: permissions, hooks: hooks, toolDirectories: [])
    }
    func files() throws -> [String: Data] { try consumerFiles(root) }
    func clean() {
        defaults.removePersistentDomain(forName: identity.defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class RequirementsOwnerFixture {
    let root: URL
    let identity: HostIdentity
    let store: ExtensionPackageStore
    var activation: HostRequirementsCLIAdapter.Activation
    var inspections = 0; var setups = 0
    var change: String?; var cancel = false; var cancelTool = false; var wrongOwner = false
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "requirements-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.owner-" + UUID().uuidString, supportDirectory: root)
        store = .init(root: root)
        activation = .init(
            enabled: true, active: true, version: "1.0.0", processIdentifier: 123,
            disablePending: false, removalPending: false)
    }
    func state(
        active: Bool = true, version: String = "1.0.0", pid: Int32 = 123, disable: Bool = false,
        removal: Bool = false
    ) -> HostRequirementsCLIAdapter.Activation {
        .init(
            enabled: true, active: active, version: version, processIdentifier: pid,
            disablePending: disable, removalPending: removal)
    }
    func reset() {
        activation = state(); inspections = 0; setups = 0; change = nil; cancel = false;
        cancelTool = false; wrongOwner = false
    }
    func mutate() {
        switch change {
        case "version": activation = state(version: "2.0.0")
        case "pid": activation = state(pid: 456)
        case "disable": activation = state(disable: true)
        case "removal": activation = state(removal: true)
        default: break
        }
    }
    func report(_ id: String) -> HostCoreReadinessReport {
        .init(
            owner: wrongOwner ? "other" : id, id: id, title: "Synthetic",
            state: .init(
                extensionID: id, phase: .ready, summary: "Captured synthetic owner inspection"),
            checks: [
                .init(
                    id: "synthetic", title: "Synthetic", status: .passed,
                    detail: "Captured synthetic owner state")
            ])
    }
    func environment() -> HostRequirementsCLIAdapter.Environment {
        var environment = HostRequirementsCLIAdapter.Environment(
            identity: identity, store: store, hostABI: HostContract.compatibility,
            architecture: "arm64",
            systemVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0),
            expectedRoles: HostRequirementsCLIAdapter.packagedRoles, signaturePolicy: .development,
            permissions: {
                Dictionary(uniqueKeysWithValues: HostPermission.allCases.map { ($0, true) })
            },
            activation: { _ in self.activation },
            tool: { _ in
                if self.cancelTool { throw CancellationError() }; return .available("22.20.0")
            },
            inspectOwner: { id in
                self.inspections += 1; if self.cancel { throw CancellationError() }; self.mutate();
                return self.report(id)
            },
            setupOwner: { id, _ in
                self.setups += 1; if self.cancel { throw CancellationError() }; self.mutate()
                let report = self.report(id)
                let document: [String: Any] = [
                    "owner": id, "id": id, "dryRun": false, "changed": false, "plannedTools": [],
                    "installedTools": [], "installFailures": [],
                    "report": try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)),
                ]
                return try JSONDecoder().decode(
                    HostCoreReadinessSetup.self,
                    from: JSONSerialization.data(withJSONObject: document))
            })
        environment.inspectPackage = { _, _, enabled, active in
            .installed(version: "1.0.0", enabled: enabled, active: active)
        }
        return environment
    }
    func files() throws -> [String: Data] { try consumerFiles(root) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private func consumerFiles(_ root: URL) throws -> [String: Data] {
    let enumerator = try #require(
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: Data] = [:]
    for case let file as URL in enumerator
    where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[file.path] = try Data(contentsOf: file)
    }
    return result
}
