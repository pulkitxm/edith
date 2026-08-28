import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithCore
@testable import EdithKit

@Suite struct CLIExtensionLifecycleTests {
    @Test func everyLifecycleCommandParsesThroughTheProductionRoot() {
        var commands: [String] = []
        for descriptor in ExtensionLifecycleCatalog.descriptors {
            commands += descriptor.cliExamples
            commands += descriptor.prerequisites.compactMap(\.command)
            commands += descriptor.recovery.compactMap(\.command)
            commands += descriptor.verification.compactMap(\.command)
        }

        for command in commands {
            let words = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            #expect(words.first == "ed")
            do {
                _ = try EdRoot.parseAsRoot(Array(words.dropFirst()))
            } catch is CleanExit {
            } catch {
                Issue.record("\(command) does not parse: \(error.localizedDescription)")
            }
        }
    }

    @Test func statusReportsAllExtensionsInRegistryOrder() async {
        await CLIProbe.inWorld { world in
            for entry in ExtensionRegistry.entries {
                world.shared.set(false, forKey: entry.defaultsKey)
            }
            let result = await CLIProbe.capture(["extensions", "status", "--json"])
            let rows = result.array as? [[String: Any]] ?? []

            #expect(result.code == 0)
            #expect(rows.compactMap { $0["id"] as? String } == ExtensionRegistry.entries.map(\.id))
            #expect(
                rows.allSatisfy {
                    ($0["state"] as? [String: Any])?["phase"] as? String == "disabled"
                })
        }
    }

    @Test func statusForOneExtensionHasStableStructuredFields() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture([
                "extensions", "status", "quinjet", "--json",
            ])

            #expect(
                Set(result.object?.keys ?? [:].keys)
                    == ["id", "title", "verified", "state", "checks", "remediation"])
            let checks = result.object?["checks"] as? [[String: Any]]
            #expect(checks?.first?["id"] as? String == "enabled")
            #expect(checks?.contains { $0["id"] as? String == "tool.quinjet" } == true)
            #expect(checks?.contains { $0["id"] as? String == "adapter.quinjet" } == true)
            let state = result.object?["state"] as? [String: Any]
            #expect(
                Set(state?.keys ?? [:].keys)
                    == ["extensionID", "phase", "runtimePhase", "summary", "issues"])
            #expect(state?["runtimePhase"] as? String == "uninstalled")
        }
    }

    @Test func setupDryRunProjectsEnablementWithoutWriting() async {
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture([
                "extensions", "setup", "quinjet", "--dry-run", "--json",
            ])
            let report = result.object?["report"] as? [String: Any]
            let state = report?["state"] as? [String: Any]

            #expect(result.object?["dryRun"] as? Bool == true)
            #expect(result.object?["changed"] as? Bool == false)
            #expect(state?["phase"] as? String == "needsSetup")
            #expect(!world.shared.bool(forKey: AppStorageKeys.Tabs.quinjetEnabled))
        }
    }

    @Test func setupEnablesAndReturnsRemainingPermissionWork() async {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            let result = await CLIProbe.capture([
                "extensions", "setup", "calendar", "--json",
            ])
            let report = result.object?["report"] as? [String: Any]
            let state = report?["state"] as? [String: Any]

            #expect(result.object?["changed"] as? Bool == true)
            #expect(world.shared.bool(forKey: AppStorageKeys.Tabs.calendarEnabled))
            #expect(state?["phase"] as? String == "needsSetup")
            #expect(
                (report?["remediation"] as? [String])?.contains(
                    "ed permissions request calendar") == true)
        }
    }

    @Test func verifyCanProveAConfiguredExtensionReady() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Tabs.quinjetEnabled)
            CLIEnvironment.executableNamed = { name in
                name == "quinjet" ? URL(fileURLWithPath: "/opt/homebrew/bin/quinjet") : nil
            }
            CLIEnvironment.extensionToolReadiness = {
                $0 == "quinjet" ? .installed(version: "quinjet 1.0") : .uninstalled
            }
            let result = await CLIProbe.capture([
                "extensions", "verify", "quinjet", "--json",
            ])

            #expect(result.object?["verified"] as? Bool == true)
            #expect((result.object?["state"] as? [String: Any])?["phase"] as? String == "ready")
            #expect(
                (result.object?["state"] as? [String: Any])?["runtimePhase"] as? String
                    == "installed")
        }
    }

    @Test func verifyDistinguishesABrokenExecutableFromAnUninstalledTool() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Tabs.quinjetEnabled)
            CLIEnvironment.extensionToolReadiness = { _ in
                .error("Found Quinjet, but its version probe failed.")
            }

            let result = await CLIProbe.capture([
                "extensions", "verify", "quinjet", "--json",
            ])
            let state = result.object?["state"] as? [String: Any]
            let checks = result.object?["checks"] as? [[String: Any]]

            #expect(result.code == 0)
            #expect(result.object?["verified"] as? Bool == false)
            #expect(state?["phase"] as? String == "failed")
            #expect(state?["runtimePhase"] as? String == "error")
            #expect(
                checks?.first { $0["id"] as? String == "tool.quinjet" }?["runtimePhase"] as? String
                    == "error")
        }
    }

    @Test func doctorReturnsActionableHelperFailures() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.MenuBar.systemStats)
            let result = await CLIProbe.capture([
                "extensions", "doctor", "systemStats", "--json",
            ])

            #expect(
                (result.object?["state"] as? [String: Any])?["phase"] as? String == "needsSetup")
            #expect(
                (result.object?["remediation"] as? [String])?.contains("ed app relaunch --yes")
                    == true)
        }
    }

    @Test func calendarDoctorUsesTheAuthorizedHelper() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Tabs.calendarEnabled)
            world.shared.set(true, forKey: AppStorageKeys.Permissions.calendarGranted)
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.calendarEvents else { return nil }
                return [
                    CalendarEventBridge.statusKey: "ok",
                    CalendarEventBridge.payloadKey: CalendarEventBridge.encode([]),
                ]
            }

            let result = await CLIProbe.capture([
                "extensions", "doctor", "calendar", "--json",
            ])

            #expect(result.object?["verified"] as? Bool == true)
            #expect(
                (result.object?["state"] as? [String: Any])?["phase"] as? String == "ready")
        }
    }

    @Test func calendarDoctorTrustsAHelperRejectionOverMirroredPermission() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Tabs.calendarEnabled)
            world.shared.set(true, forKey: AppStorageKeys.Permissions.calendarGranted)
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.calendarEvents else { return nil }
                return [CalendarEventBridge.statusKey: "notAuthorized"]
            }

            let result = await CLIProbe.capture([
                "extensions", "doctor", "calendar", "--json",
            ])

            #expect(result.object?["verified"] as? Bool == false)
            #expect(
                (result.object?["state"] as? [String: Any])?["phase"] as? String == "needsSetup")
        }
    }

    @Test func statusIncludesTheLiveRuntimeAdapter() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Tabs.quinjetEnabled)
            CLIEnvironment.executableNamed = { name in
                name == "quinjet" ? URL(fileURLWithPath: "/opt/homebrew/bin/quinjet") : nil
            }
            CLIEnvironment.extensionToolReadiness = {
                $0 == "quinjet" ? .installed(version: "quinjet 1.0") : .uninstalled
            }

            let result = await CLIProbe.capture([
                "extensions", "status", "quinjet", "--json",
            ])
            let checks = result.object?["checks"] as? [[String: Any]]

            #expect(result.code == 0)
            #expect(
                checks?.first { $0["id"] as? String == "adapter.quinjet" }?["status"] as? String
                    == "passed")
            #expect(result.object?["verified"] as? Bool == true)
        }
    }

    @Test func companionStatusRoutesFreshSetupAndConfiguredRecovery() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Tabs.companionEnabled)
            CLIEnvironment.companionConfigured = { false }
            let fresh = await CLIProbe.capture([
                "extensions", "status", "companion", "--json",
            ])

            CLIEnvironment.companionConfigured = { true }
            let configured = await CLIProbe.capture([
                "extensions", "status", "companion", "--json",
            ])

            #expect((fresh.object?["state"] as? [String: Any])?["phase"] as? String == "needsSetup")
            #expect(
                (fresh.object?["remediation"] as? [String])?.contains("ed companion deploy") == true
            )
            #expect(
                (configured.object?["state"] as? [String: Any])?["phase"] as? String == "failed")
            #expect(
                (configured.object?["remediation"] as? [String])?.contains(
                    "ed companion doctor --json") == true)
        }
    }

    @Test func companionEndpointUsesTheInjectedSharedDefaults() async {
        await CLIProbe.inWorld { world in
            world.shared.set(
                "http://127.0.0.1:4821", forKey: AppStorageKeys.Companion.endpoint)
            #expect(CLIEnvironment.resolvedCompanionEndpoint(nil).port == 4821)
        }
    }

    @Test func plainInfoIncludesVerificationAndRecoveryCommands() async {
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["extensions", "info", "notchShelf"])

            #expect(result.code == 0)
            #expect(result.stdout.contains("  verify\n"))
            #expect(result.stdout.contains("    ed shelf ls --json\n"))
            #expect(result.stdout.contains("  recover\n"))
            #expect(result.stdout.contains("    ed shelf clear --yes --json\n"))
        }
    }
}

@Suite(.serialized) struct CLIExtensionMutationProcessTests {
    @Test func shippedEntryPreservesPlainAndJSONMutationContracts() throws {
        let suite = "CLIExtensionMutationProcessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_TEST_SHARED_DEFAULTS_SUITE"] = suite

        let plain = try CLIProcessProbe.run(
            ["extensions", "enable", "calendar"], environment: environment)
        defaults.synchronize()

        #expect(plain.code == 0)
        #expect(plain.stdout == "calendar enabled\n")
        #expect(plain.stderr.contains("ed permissions request calendar"))
        #expect(defaults.bool(forKey: AppStorageKeys.Tabs.calendarEnabled))

        let json = try CLIProcessProbe.run(
            ["extensions", "disable", "calendar", "--json"], environment: environment)
        defaults.synchronize()

        #expect(json.code == 0)
        #expect(json.stderr.isEmpty)
        #expect(json.object?["id"] as? String == "calendar")
        #expect(json.object?["enabled"] as? Bool == false)
        #expect(!defaults.bool(forKey: AppStorageKeys.Tabs.calendarEnabled))
    }

    @Test func processJSONContainsAnExplicitRuntimeAdapterCheck() throws {
        let suite = "CLIExtensionRuntimeProcessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
        defaults.set(true, forKey: AppStorageKeys.Permissions.screenRecordingGranted)
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_TEST_SHARED_DEFAULTS_SUITE"] = suite

        let result = try CLIProcessProbe.run(
            ["extensions", "status", "presenter", "--json"], environment: environment)
        let checks = result.object?["checks"] as? [[String: Any]]

        #expect(result.code == 0)
        #expect(checks?.contains { $0["id"] as? String == "adapter.presenter" } == true)
    }
}
