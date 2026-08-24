import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIExtensionLifecycleTests {
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
            #expect((result.object?["checks"] as? [[String: Any]])?.count == 1)
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
