import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostExtensionRequirementsTests {
    @Test func exactOriginalInventoryAndExtractedOwnersStayDistinct() throws {
        let entries = HostExtensionRequirementCatalog.entries
        #expect(entries.count == 39)
        #expect(Set(entries.map(\.id)).count == 39)
        #expect(
            Set(entries.filter { $0.original == nil }.map(\.id)) == [
                "jev", "docs", "terminal", "machines",
            ])
        #expect(try HostExtensionRequirementCatalog.entry(id: "usage").original?.toolRule == .any)
        #expect(
            try HostExtensionRequirementCatalog.entry(id: "downloads").original?.requiredTools == [
                "yt-dlp", "ffmpeg", "deno",
            ])
        #expect(
            try HostExtensionRequirementCatalog.entry(id: "latex").original?.optionalTools == [
                "tectonic", "latexmk", "gh", "quinjet", "pukbot",
            ])
        #expect(
            try HostExtensionRequirementCatalog.entry(id: "audioMixer").dependencies == [
                "notchShelf"
            ])
        #expect(
            try HostExtensionRequirementCatalog.entry(id: "homebrew").dependencies == [
                "appMaintenance"
            ])
        #expect(throws: HostCLIError.self) {
            try HostExtensionRequirementCatalog.entry(id: "camera")
        }
    }

    @Test(arguments: HostExtensionRequirementCatalog.entries.map(\.id))
    func absentAndDisabledStillInspectOriginalRequirements(id: String) async throws {
        let fixture = RequirementFixture()
        fixture.package = .absent
        let report = try await fixture.service.inspect(id: id)
        #expect(!report.verified)
        #expect(report.checks.contains { $0.id == "package" && $0.status == .failed })
        let original = try HostExtensionRequirementCatalog.entry(id: id).original
        for permission in (original?.requiredPermissions ?? [])
            + (original?.optionalPermissions ?? [])
        {
            #expect(fixture.permissions.contains(permission))
        }
        for tool in (original?.requiredTools ?? []) + (original?.optionalTools ?? []) {
            #expect(fixture.tools.contains(tool))
        }
        fixture.package = .installed(version: "1.0.0", enabled: false, active: false)
        let disabled = try await fixture.service.inspect(id: id)
        #expect(disabled.state.phase == .disabled)
        #expect(!disabled.verified)
        #expect(fixture.setupCalls == 0)
    }

    @Test func usageAcceptsOneVerifiedProviderAndDoesNotRequireBoth() async throws {
        let fixture = RequirementFixture()
        fixture.toolStates = ["claude": .missing("Not installed"), "codex": .available("1.2.3")]
        let report = try await fixture.service.inspect(id: "usage")
        #expect(report.checks.first { $0.id == "tool.provider" }?.status == .passed)
        fixture.toolStates["codex"] = .unknown("Version probe failed")
        let failed = try await fixture.service.inspect(id: "usage")
        #expect(failed.checks.first { $0.id == "tool.provider" }?.status == .failed)
        #expect(!failed.verified)
    }

    @Test func requiredOptionalAndUnsupportedObservationsRemainVisible() async throws {
        let fixture = RequirementFixture()
        fixture.permissionStates = [
            "screenRecording": .missing("Denied"), "applicationAudio": .unknown("Not inspected"),
        ]
        fixture.capabilityStates["applicationAudio"] = .unsupported("Requires macOS 14.4")
        let focus = try await fixture.service.inspect(id: "focusDim")
        #expect(focus.checks.first { $0.id == "permission.screenRecording" }?.status == .failed)
        let audio = try await fixture.service.inspect(id: "audioMixer")
        #expect(audio.checks.first { $0.id == "permission.applicationAudio" }?.status == .warning)
        #expect(audio.state.runtimePhase == .unsupported)
        #expect(audio.state.phase == .unavailable)
        #expect(!audio.verified)
    }

    @Test(arguments: ["jev", "docs", "terminal", "machines", "systemStats", "companion"])
    func missingPureOwnerInspectionNeverMeansHealthy(id: String) async throws {
        let fixture = RequirementFixture(); fixture.ownerAvailable = false
        let report = try await fixture.service.inspect(id: id)
        #expect(!report.verified)
        #expect(report.checks.first { $0.id == "owner.inspection" }?.status == .failed)
    }

    @Test func pluginsRetainsNodeAndNpxConstraintsAndBrowsingPreview() async throws {
        let fixture = RequirementFixture()
        fixture.toolStates["node"] = .unsupported("Node.js 22.20 or later is required")
        fixture.toolStates["npx"] = .missing("npx is missing")
        let report = try await fixture.service.inspect(id: "plugins")
        #expect(!report.verified)
        #expect(report.checks.first { $0.id == "tool.node" }?.status == .failed)
        #expect(report.checks.first { $0.id == "tool.npx" }?.status == .failed)
        let preview = try await fixture.service.preview(id: "plugins", installTools: true)
        #expect(preview.instruction.contains("Browsing is available now"))
    }

    @Test func herdrUsesActualHostInventoryAndPreservesEmptyAndFailureStates() async throws {
        let fixture = RequirementFixture(); fixture.hosts = nil
        #expect(try await fixture.service.inspect(id: "herdr").verified == false)
        fixture.hosts = []
        #expect(
            try await fixture.service.inspect(id: "herdr").checks.last?.runtimePhase == .uninstalled
        )
        fixture.hosts = [.init(id: "local", present: true, liveSessions: 0)]
        #expect(try await fixture.service.inspect(id: "herdr").checks.last?.runtimePhase == .empty)
        fixture.hosts = [
            .init(id: "local", present: true, liveSessions: 2),
            .init(
                id: "remote", present: false, liveSessions: 0,
                error: "Unavailable captured inventory"),
        ]
        let report = try await fixture.service.inspect(id: "herdr")
        #expect(report.checks.last?.status == .warning)
        #expect(report.checks.last?.detail.contains("2 live sessions") == true)
        #expect(!report.verified)
        fixture.hosts = [.init(id: "local", present: true, liveSessions: -1)]
        await #expect(throws: HostCLIError.self) { try await fixture.service.inspect(id: "herdr") }
    }

    @Test func dryRunPreservesOriginalPlanWithNoSetupCallsEvenAbsent() async throws {
        let fixture = RequirementFixture(); fixture.package = .absent
        fixture.toolStates = [
            "yt-dlp": .missing("Not installed"), "ffmpeg": .available("8.0"),
            "deno": .missing("Not installed"),
        ]
        let result = try await fixture.service.setup(
            id: "downloads", dryRun: true, installTools: true)
        try result.validate(owner: "downloads", dryRun: true, installTools: true)
        #expect(result.plannedTools == ["yt-dlp", "deno"])
        #expect(!result.changed && result.installedTools.isEmpty && result.installFailures.isEmpty)
        #expect(fixture.package == .absent && fixture.setupCalls == 0)
        #expect(
            result.report.checks.last?.detail.contains(
                "Choose an existing, writable download folder.") == true)
    }

    @Test func nonDrySetupRequiresExistingActiveOwnerAndRejectsDisableDuringDelegation()
        async throws
    {
        let fixture = RequirementFixture()
        for package in [
            HostRequirementPackageState.absent, .incompatible, .invalid("Bad signature"),
            .installed(version: "1.0.0", enabled: false, active: false),
            .installed(version: "1.0.0", enabled: true, active: false),
        ] {
            fixture.package = package
            await #expect(throws: HostCLIError.self) {
                try await fixture.service.setup(id: "downloads", dryRun: false, installTools: false)
            }
        }
        #expect(fixture.setupCalls == 0)
        fixture.package = .installed(version: "1.0.0", enabled: true, active: true)
        let accepted = try await fixture.service.setup(
            id: "downloads", dryRun: false, installTools: false)
        #expect(accepted.id == "downloads" && fixture.setupCalls == 1)
        fixture.disableDuringSetup = true
        await #expect(throws: HostCLIError.self) {
            try await fixture.service.setup(id: "downloads", dryRun: false, installTools: false)
        }
    }

    @Test func wrongOwnerInspectionAndCancellationAreRejected() async throws {
        let fixture = RequirementFixture(); fixture.inspectionOwner = "other"
        await #expect(throws: HostCLIError.self) { try await fixture.service.inspect(id: "system") }
        fixture.inspectionOwner = nil; fixture.cancelTool = true
        await #expect(throws: CancellationError.self) {
            try await fixture.service.inspect(id: "downloads")
        }
    }

    @Test func malformedOwnerObservationsVersionReplacementAndToolFailuresAreRejected() async throws
    {
        let fixture = RequirementFixture()
        fixture.ownerStatus = .skipped
        await #expect(throws: HostCLIError.self) { try await fixture.service.inspect(id: "system") }
        fixture.ownerStatus = .passed; fixture.ownerPhase = .unsupported
        await #expect(throws: HostCLIError.self) { try await fixture.service.inspect(id: "system") }
        fixture.ownerPhase = .installed
        fixture.toolStates = [
            "claude": .failed("Version probe failed"), "codex": .missing("Not installed"),
        ]
        let report = try await fixture.service.inspect(id: "usage")
        #expect(report.state.phase == .failed && report.state.runtimePhase == .error)
        fixture.changeVersionDuringSetup = true
        await #expect(throws: HostCLIError.self) {
            try await fixture.service.setup(id: "downloads", dryRun: false, installTools: false)
        }
        #expect(fixture.setupCalls == 1)
    }

    @Test func originalPublicCLIUnhealthyReportsExitZeroAndInactiveDryRunWorks() async throws {
        let fixture = RequirementFixture(); fixture.package = .absent;
        fixture.ownerAvailable = false
        let service = fixture.service
        let cli = HostCoreReadinessCLI(
            backend: .init(
                entries: {
                    HostExtensionRequirementCatalog.entries.map {
                        .init(id: $0.id, title: $0.title)
                    }
                },
                inspect: { id, _ in try await service.inspect(id: id) },
                setup: { try await service.setup(id: $0, dryRun: $1, installTools: $2) }))
        for command in ["status", "verify", "doctor"] {
            let reply = try await cli.execute([command, "downloads", "--json"])
            #expect(reply.exitCode == 0)
            #expect(
                try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any]
                    != nil)
            let value = try #require(
                try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
            #expect(value["verified"] as? Bool == false)
        }
        let reply = try await cli.execute(["setup", "downloads", "--dry-run", "--json"])
        #expect(reply.exitCode == 0 && fixture.setupCalls == 0)
        #expect(reply.stdout.contains("setup.preview"))
    }
}

@MainActor private final class RequirementFixture {
    var package: HostRequirementPackageState = .installed(
        version: "1.0.0", enabled: true, active: true)
    var permissionStates: [String: HostRequirementObservation] = [:]
    var capabilityStates: [String: HostRequirementObservation] = [:]
    var toolStates: [String: HostRequirementObservation] = [:]
    var permissions: [String] = []; var tools: [String] = []
    var ownerAvailable = true; var inspectionOwner: String?; var cancelTool = false
    var hosts: [HostRequirementHerdrHost]? = [.init(id: "local", present: true, liveSessions: 1)]
    var setupCalls = 0; var disableDuringSetup = false; var changeVersionDuringSetup = false
    var ownerPhase: HostCoreReadinessRuntimePhase = .installed
    var ownerStatus: HostCoreReadinessCheckStatus = .passed
    var service: HostExtensionRequirementsService {
        HostExtensionRequirementsService(
            environment: .init(
                package: { _ in self.package },
                permission: {
                    self.permissions.append($0);
                    return self.permissionStates[$0] ?? .available("Granted synthetic observation")
                },
                capability: {
                    self.capabilityStates[$0] ?? .available("Supported synthetic capability")
                },
                tool: {
                    self.tools.append($0); if self.cancelTool { throw CancellationError() }
                    return self.toolStates[$0] ?? .available("1.2.3")
                },
                ownerInspection: { id in
                    self.ownerAvailable
                        ? .init(
                            owner: self.inspectionOwner ?? id,
                            phase: self.ownerPhase, status: self.ownerStatus,
                            detail: "Synthetic pure inspection")
                        : nil
                },
                herdrInventory: { self.hosts },
                activeSetup: { id, _ in
                    self.setupCalls += 1
                    let report = try await self.service.inspect(id: id)
                    if self.disableDuringSetup {
                        self.package = .installed(version: "1.0.0", enabled: false, active: false)
                    }
                    if self.changeVersionDuringSetup {
                        self.package = .installed(version: "2.0.0", enabled: true, active: true)
                    }
                    return .init(
                        owner: id, id: id, dryRun: false, changed: false,
                        plannedTools: [], installedTools: [], installFailures: [], report: report)
                }))
    }
}

@Suite @MainActor struct HostRequirementToolProbeTests {
    @Test func actualBoundedVersionExecutionSeparatesOutputAndRejectsUnboundedWork() async throws {
        let output = try await HostRequirementToolProbe.execute(
            URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["synthetic 22.20.0\\n"])
        #expect(
            output.status == 0 && output.stdout == "synthetic 22.20.0\n" && output.stderr.isEmpty)
        await #expect(throws: HostCLIError.self) {
            try await HostRequirementToolProbe.execute(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(40))
        }
        await #expect(throws: HostCLIError.self) {
            try await HostRequirementToolProbe.execute(
                URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["synthetic"],
                maximumOutputBytes: 32)
        }
        let task = Task {
            try await HostRequirementToolProbe.execute(
                URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func injectedVersionProbesUseExactArgumentsAndMinimumNodeVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "requirement-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["node", "npx"] {
            let path = root.appendingPathComponent(name)
            try Data("synthetic".utf8).write(to: path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let old = HostRequirementToolProbe(
            directories: [root],
            run: { path, args in
                #expect(path.lastPathComponent == "node" && args == ["--version"])
                return .init(status: 0, stdout: "v22.19.0", stderr: "")
            })
        #expect(
            try await old.inspect(id: "node")
                == .unsupported(
                    "Plugins installation requires Node.js 22.20 or later. Found 22.19.0. Browsing remains available."
                ))
        let fresh = HostRequirementToolProbe(
            directories: [root], run: { _, _ in .init(status: 0, stdout: "v22.20.0", stderr: "") })
        #expect(try await fresh.inspect(id: "node") == .available("22.20.0"))
        #expect(try await fresh.inspect(id: "npx") == .available("22.20.0"))
        #expect(
            try await fresh.inspect(id: "git")
                == .missing("git is not in the explicit executable search path."))
        let broken = HostRequirementToolProbe(
            directories: [root],
            run: { _, _ in .init(status: 1, stdout: "v22.20.0", stderr: "failed") })
        #expect(
            try await broken.inspect(id: "node")
                == .failed("node was found, but its version probe failed."))
        await #expect(throws: HostCLIError.self) { try await fresh.inspect(id: "invented") }
    }

    @Test func liveProbeUsesExplicitInterpreterPathAndNoUserConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "requirement-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = [
            "node": "#!/bin/sh\nexec /usr/bin/printf 'v22.20.0\\n'\n",
            "npx": "#!/usr/bin/env node\n",
        ]
        for (name, script) in scripts {
            let path = root.appendingPathComponent(name)
            try Data(script.utf8).write(to: path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let probe = HostRequirementToolProbe(directories: [root])
        #expect(try await probe.inspect(id: "node") == .available("22.20.0"))
        #expect(try await probe.inspect(id: "npx") == .available("22.20.0"))
        let environment = try await HostRequirementToolProbe.execute(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: [])
        #expect(environment.stdout.contains("HOME=/var/empty"))
        #expect(environment.stdout.contains("npm_config_userconfig=/dev/null"))
        #expect(!environment.stdout.contains("USER="))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [
                "node", "npx",
            ])
        #expect(!HostRequirementToolProbe.nodeSupported("22.20.0-beta.1"))
    }

    @Test func originalMacOSCapabilitiesRetainVersionGates() {
        let old = OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 0)
        #expect(
            HostRequirementPlatform.macOS(capability: "applicationAudio", version: old)
                == .unsupported("Application audio mixing requires macOS 14.4 or later."))
        #expect(
            HostRequirementPlatform.macOS(capability: "screenTimeLapse", version: old)
                == .unsupported("Screen recording requires macOS 15 or later."))
        #expect(
            HostRequirementPlatform.macOS(capability: "invented", version: old)
                == .unsupported("No original platform implementation for invented."))
    }
}
