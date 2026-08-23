import Foundation
import Testing

import EdithCore
@testable import EdithKit

@Suite struct ExtensionLifecycleProbeTests {
    @Test func policiesCoverTheRegistryExactly() {
        #expect(
            Set(ExtensionLifecycleProbe.policies.keys) == Set(ExtensionRegistry.entries.map(\.id)))
    }

    @Test func disabledExtensionsSkipReadinessChecks() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        let report = await probe(enabled: false).report(for: entry)

        #expect(report.state.phase == .disabled)
        #expect(report.checks.map(\.status) == [.skipped])
        #expect(report.checks.first?.recoveryCommand == "ed extensions setup quinjet")
    }

    @Test func aSupportedExtensionWithItsToolIsReady() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "quinjet" })
        let report = await probe(tools: ["quinjet"]).report(for: entry)

        #expect(report.state.phase == .ready)
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
        #expect(report.state.issues.map(\.id) == ["platform"])
    }

    @Test func backendFailureIsDifferentFromIncompleteSetup() async throws {
        let entry = try #require(ExtensionRegistry.entries.first { $0.id == "companion" })
        let report = await probe(adapter: .failed("Database is unavailable.")).report(for: entry)

        #expect(report.state.phase == .failed)
        #expect(report.state.issues.first?.id == "backend.companion")
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
                == .needsSetup("Herdr is not installed on this Mac or a configured machine."))
        #expect(
            ExtensionLifecycleProbeEnvironment.herdrReadiness(empty)
                == .needsSetup("Herdr is installed, but no live sessions were found."))
        #expect(
            ExtensionLifecycleProbeEnvironment.herdrReadiness(ready)
                == .ready("Found 1 live Herdr sessions."))
    }

    private func probe(
        enabled: Bool = true, permissions: [ExtensionPermission: Bool] = [:],
        tools: Set<String> = [], helperRunning: Bool = false,
        platform: PlatformCapabilities = .macOS, machineCount: Int = 0,
        adapter: ExtensionAdapterReadiness? = nil
    ) -> ExtensionLifecycleProbe {
        ExtensionLifecycleProbe(
            environment: ExtensionLifecycleProbeEnvironment(
                isEnabled: { _ in enabled }, grantedPermissions: { permissions },
                toolAvailable: { tools.contains($0) }, helperRunning: { helperRunning },
                platformCapabilities: platform, machineCount: { machineCount },
                adapterReadiness: { _ in adapter }))
    }
}
