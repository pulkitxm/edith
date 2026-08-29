import Foundation
import Testing

import EdithCore
@testable import EdithKit

@Suite struct ExtensionLifecycleProbeTests {
    struct MatrixRow {
        let id: String
        let helper: Bool
        let machine: Bool
        let toolRule: ExtensionLifecycleProbe.ToolRule
        let adapter: Bool
        let requiredTools: [String]
        let optionalTools: [String]
    }

    static let matrix = [
        MatrixRow(
            id: "attention", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "usage", helper: true, machine: false, toolRule: .any, adapter: true,
            requiredTools: ["claude", "codex"], optionalTools: []),
        MatrixRow(
            id: "herdr", helper: false, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "quinjet", helper: false, machine: false, toolRule: .all, adapter: true,
            requiredTools: ["quinjet"], optionalTools: []),
        MatrixRow(
            id: "github", helper: false, machine: false, toolRule: .all, adapter: true,
            requiredTools: ["gh"], optionalTools: []),
        MatrixRow(
            id: "system", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "machines", helper: true, machine: true, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "companion", helper: false, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "systemStats", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "micMute", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "lidAwake", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "music", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: ["yt-dlp"]),
        MatrixRow(
            id: "calendar", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "notchShelf", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "clipboard", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "focusDim", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "presenter", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "emoji", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
        MatrixRow(
            id: "colorPicker", helper: true, machine: false, toolRule: .all, adapter: true,
            requiredTools: [], optionalTools: []),
    ]

    @Test func policiesCoverTheRegistryExactly() {
        #expect(
            Set(ExtensionLifecycleProbe.policies.keys) == Set(ExtensionRegistry.entries.map(\.id)))
    }

    @Test func allRegisteredExtensionsHaveAnExplicitHealthyStateMatrix() async throws {
        #expect(Self.matrix.map(\.id) == ExtensionRegistry.entries.map(\.id))
        let permissions = Dictionary(
            uniqueKeysWithValues: ExtensionPermission.allCases.map { ($0, true) })
        let tools = Set(Self.matrix.flatMap { $0.requiredTools + $0.optionalTools })

        for row in Self.matrix {
            let entry = try #require(ExtensionRegistry.entries.first { $0.id == row.id })
            let policy = try #require(ExtensionLifecycleProbe.policies[row.id])
            #expect(policy.requiresHelper == row.helper, "\(row.id) helper policy drifted")
            #expect(policy.requiresMachine == row.machine, "\(row.id) machine policy drifted")
            #expect(policy.toolRule == row.toolRule, "\(row.id) tool rule drifted")
            #expect(policy.adapter == row.adapter, "\(row.id) adapter policy drifted")
            #expect(entry.requiredToolIDs == row.requiredTools, "\(row.id) core tools drifted")
            #expect(entry.optionalToolIDs == row.optionalTools, "\(row.id) workflow tools drifted")

            let report = await probe(
                permissions: permissions, tools: tools, helperRunning: true, machineCount: 1,
                adapter: .ready("Ready.")
            ).report(for: entry)
            #expect(report.state.phase == .ready, "\(row.id) is not ready")
            #expect(report.state.runtimePhase == .installed, "\(row.id) is not installed")
        }
    }

    @Test func disabledExtensionsStillReportTheirRealRuntime() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        let installed = await probe(enabled: false, tools: ["quinjet"]).report(for: entry)
        let missing = await probe(enabled: false).report(for: entry)

        #expect(installed.state.phase == .disabled)
        #expect(installed.state.runtimePhase == .installed)
        #expect(installed.checks.first?.status == .skipped)
        #expect(installed.checks.first?.recoveryCommand == "ed extensions setup quinjet")
        #expect(installed.checks.contains { $0.id == "tool.quinjet" && $0.status == .passed })
        #expect(missing.state.phase == .disabled)
        #expect(missing.state.runtimePhase == .uninstalled)
    }

    @Test func aSupportedExtensionWithItsToolIsReady() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        let report = await probe(tools: ["quinjet"]).report(for: entry)

        #expect(report.state.phase == .ready)
        #expect(report.state.runtimePhase == .installed)
        #expect(report.verified)
        #expect(report.state.issues.isEmpty)
    }

    @Test func requiredPermissionsProduceActionableSetupState() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "calendar" })
        let report = await probe(helperRunning: true).report(for: entry)

        #expect(report.state.phase == .needsSetup)
        #expect(report.state.issues.map(\.id).contains("permission.calendar"))
        #expect(
            report.state.issues.first { $0.id == "permission.calendar" }?.recoveryCommand
                == "ed permissions request calendar")
    }

    @Test func usageAcceptsEitherProviderTool() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "usage" })
        let report = await probe(
            permissions: [.notifications: true], tools: ["claude"], helperRunning: true
        ).report(for: entry)

        #expect(report.state.phase == .ready)
        #expect(report.checks.first { $0.id == "tool.provider" }?.status == .passed)
    }

    @Test func missingHelperAndMachineConfigurationNeedSetup() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "machines" })
        let report = await probe(
            permissions: [.notifications: true], helperRunning: false, machineCount: 0
        ).report(for: entry)

        #expect(report.state.phase == .needsSetup)
        #expect(Set(report.state.issues.map(\.id)).isSuperset(of: ["helper", "machines"]))
    }

    @Test func missingRequiredPlatformCapabilityIsUnavailable() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        var states = PlatformCapabilities.macOS.states
        states[.localTerminal] = .unsupported("No terminal adapter.")
        let report = await probe(
            tools: ["quinjet"], platform: PlatformCapabilities(states: states)
        ).report(for: entry)

        #expect(report.state.phase == .unavailable)
        #expect(report.state.runtimePhase == .unsupported)
        #expect(report.state.issues.map(\.id) == ["platform"])
    }

    @Test func oldMacOSOnlyDegradesNotchShelfWhenAudioMixerIsEnabled() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "notchShelf" })
        let platform = PlatformCapabilities.macOS(
            version: OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 0))
        let ready = await probe(
            permissions: [.camera: true], helperRunning: true, platform: platform,
            applicationAudioEnabled: false
        ).report(for: entry)
        let degraded = await probe(
            permissions: [.camera: true], helperRunning: true, platform: platform,
            applicationAudioEnabled: true
        ).report(for: entry)

        #expect(ready.state.phase == .ready)
        #expect(ready.state.runtimePhase == .installed)
        #expect(degraded.state.phase == .degraded)
        #expect(degraded.state.runtimePhase == .installed)
        #expect(degraded.state.issues.map(\.id) == ["platform"])
        #expect(degraded.state.issues.first?.detail.contains("applicationAudio") == true)
    }

    @Test func backendFailureIsDifferentFromIncompleteSetup() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "companion" })
        let report = await probe(adapter: .failed("Database is unavailable.")).report(for: entry)
        let missing = await probe(
            adapter: .uninstalled("Companion is not configured.")
        ).report(for: entry)

        #expect(report.state.phase == .failed)
        #expect(report.state.runtimePhase == .error)
        #expect(report.state.issues.first?.id == "backend.companion")
        #expect(report.state.issues.first?.recoveryCommand == "ed companion doctor --json")
        #expect(missing.state.phase == .needsSetup)
        #expect(missing.state.runtimePhase == .uninstalled)
        #expect(missing.state.issues.first?.recoveryCommand == "ed companion deploy")
    }

    @Test func aMissingLiveAdapterIsAnExplicitRuntimeFailure() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "system" })
        let report = await probe(helperRunning: true, adapter: nil).report(for: entry)

        #expect(report.state.phase == .failed)
        #expect(report.state.runtimePhase == .error)
        #expect(
            report.state.issues.first { $0.id == "backend.system" }?.detail
                == "No live runtime adapter is registered for system.")
    }

    @Test func runtimePhasesPreserveReadinessSemantics() async throws {
        let quinjet = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        let herdr = try #require(ExtensionRegistry.entries.first { $0.id == "herdr" })
        var unsupported = PlatformCapabilities.macOS.states
        unsupported[.localTerminal] = .unsupported("Unavailable.")

        let states = [
            await probe(enabled: false).report(for: quinjet).state,
            await probe(tools: ["quinjet"]).report(for: quinjet).state,
            await probe(adapter: .empty("No sessions.")).report(for: herdr).state,
            await probe(adapter: .loading("Reading sessions.")).report(for: herdr).state,
            await probe(
                tools: ["quinjet"], platform: PlatformCapabilities(states: unsupported)
            ).report(for: quinjet).state,
            await probe(
                toolStates: ["quinjet": .error("Version probe failed.")]
            ).report(for: quinjet).state,
        ]

        #expect(
            states.map(\.runtimePhase) == [
                .uninstalled, .installed, .empty, .loading, .unsupported, .error,
            ])
        #expect(
            states.map(\.phase) == [
                .disabled, .ready, .ready, .checking, .unavailable, .failed,
            ])
    }

    @Test func emptyInstalledRuntimeIsReadyWithoutClaimingContent() async throws {
        let herdr = try #require(ExtensionRegistry.entries.first { $0.id == "herdr" })

        let report = await probe(adapter: .empty("No sessions.")).report(for: herdr)

        #expect(report.state.phase == .ready)
        #expect(report.state.runtimePhase == .empty)
        #expect(report.state.summary.contains("no content or sessions"))
        #expect(report.checks.first { $0.id == "adapter.herdr" }?.status == .passed)
        #expect(report.state.issues.isEmpty)
    }

    @Test func optionalMusicWorkflowDoesNotBlockCoreInstallation() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "music" })
        let report = await probe(helperRunning: true).report(for: entry)

        #expect(report.state.phase == .degraded)
        #expect(report.state.runtimePhase == .installed)
        #expect(report.checks.first { $0.id == "tool.yt-dlp" }?.status == .warning)
    }

    @Test func executablePresenceRequiresASuccessfulVersionProbe() async {
        let path = URL(fileURLWithPath: "/opt/homebrew/bin/quinjet")
        let absent = await ExtensionLifecycleProbeEnvironment.toolReadiness(
            "quinjet", executableNamed: { _ in nil }, detectedVersion: { _ in "ignored" })
        let broken = await ExtensionLifecycleProbeEnvironment.toolReadiness(
            "quinjet", executableNamed: { _ in path }, detectedVersion: { _ in nil })
        let installed = await ExtensionLifecycleProbeEnvironment.toolReadiness(
            "quinjet", executableNamed: { _ in path },
            detectedVersion: { _ in "quinjet 1.2.3" })

        #expect(absent == .uninstalled)
        #expect(
            broken
                == .error(
                    "Found Quinjet at /opt/homebrew/bin/quinjet, but its version probe failed."))
        #expect(installed == .installed(version: "quinjet 1.2.3"))
    }

    @Test func companionHealthMapsBlockersAndOptionalFailures() {
        let blocked = CompanionHealth(
            ok: false,
            checks: [CompanionCheck(name: "postgres", ok: false, detail: "connection refused")])
        let degraded = CompanionHealth(
            ok: true, degraded: true,
            checks: [
                CompanionCheck(
                    name: "whisper", ok: false, severity: "optional", detail: "not installed")
            ])

        #expect(
            ExtensionLifecycleProbeEnvironment.companionReadiness(blocked)
                == .failed("postgres: connection refused"))
        #expect(
            ExtensionLifecycleProbeEnvironment.companionReadiness(degraded)
                == .degraded("whisper: not installed"))
        #expect(
            ExtensionLifecycleProbeEnvironment.companionFailureReadiness(
                "connection refused", configured: false)
                == .uninstalled(
                    "Companion is not configured. Choose a host and deploy it, or save another endpoint."
                ))
        #expect(
            ExtensionLifecycleProbeEnvironment.companionFailureReadiness(
                "connection refused", configured: true)
                == .failed("Companion backend is unreachable: connection refused"))
    }

    @Test func companionLifecycleStartsWithDeploymentAndKeepsDoctorRecovery() throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "companion" })
        let lifecycle = try #require(entry.lifecycle)

        #expect(lifecycle.prerequisites.first?.title == "Deploy or connect the backend")
        #expect(lifecycle.prerequisites.first?.command == "ed companion deploy")
        #expect(lifecycle.recovery.first?.command == "ed companion doctor --json")
    }

    @Test func herdrSnapshotsMapSessionAndHostHealth() {
        let absent = [HerdrHostSnapshot.local(herdrPresent: false)]
        let empty = [HerdrHostSnapshot.local(herdrPresent: true)]
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "default", pane: "1", kind: "agent", status: .working,
            title: "Review", workspace: "", cwd: "")
        let ready = [HerdrHostSnapshot.local(herdrPresent: true, agents: [agent])]

        #expect(
            ExtensionLifecycleProbeEnvironment.herdrReadiness(absent)
                == .uninstalled("Herdr is not installed on this Mac or a configured machine."))
        #expect(
            ExtensionLifecycleProbeEnvironment.herdrReadiness(empty)
                == .empty("Herdr is installed, but no live sessions were found."))
        #expect(
            ExtensionLifecycleProbeEnvironment.herdrReadiness(ready)
                == .ready("Found 1 live Herdr sessions."))
    }

    private func probe(
        enabled: Bool = true, permissions: [ExtensionPermission: Bool] = [:],
        tools: Set<String> = [], helperRunning: Bool = false,
        platform: PlatformCapabilities = .macOS, machineCount: Int = 0,
        adapter: ExtensionAdapterReadiness? = .ready("Ready."),
        toolStates: [String: ExtensionToolReadiness] = [:], applicationAudioEnabled: Bool = false
    ) -> ExtensionLifecycleProbe {
        ExtensionLifecycleProbe(
            environment: ExtensionLifecycleProbeEnvironment(
                isEnabled: { _ in enabled }, grantedPermissions: { permissions },
                toolReadiness: {
                    toolStates[$0]
                        ?? (tools.contains($0) ? .installed(version: "test") : .uninstalled)
                }, helperRunning: { helperRunning },
                platformCapabilities: platform,
                usesOptionalCapability: {
                    $0 != .applicationAudio || applicationAudioEnabled
                }, machineCount: { machineCount },
                adapterReadiness: { _ in adapter }))
    }
}
