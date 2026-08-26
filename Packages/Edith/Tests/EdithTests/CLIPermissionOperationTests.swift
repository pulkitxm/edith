import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIPermissionOperationTests {
    @Test func listReadsTheInjectedMirrorInPlainAndJSON() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.Permissions.calendarGranted)

            let plain = await CLIProbe.capture(["permissions", "ls"])
            let json = await CLIProbe.capture(["permissions", "ls", "--json"])
            let calendar = (json.object?["permissions"] as? [[String: Any]])?.first {
                $0["id"] as? String == "calendar"
            }

            #expect(plain.code == 0)
            #expect(plain.stdout.contains("calendar"))
            #expect(plain.stdout.contains("granted"))
            #expect(calendar?["granted"] as? Bool == true)
        }
    }

    @Test func settingsUsesTheSharedDestinationWithoutTheHelper() async {
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture([
                "permissions", "settings", "screenRecording", "--json",
            ])

            #expect(result.code == 0)
            #expect(result.object?["permission"] as? String == "screenRecording")
            #expect(result.object?["opened"] as? Bool == true)
            #expect(world.recordedURLs() == [ExtensionPermission.screenRecording.settingsURL!])
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func firstUseSettingsFailsWithoutOpeningAnything() async {
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture(["permissions", "settings", "automation"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("has no settings page"))
            #expect(world.recordedURLs().isEmpty)
        }
    }

    @Test func applicationAudioOpensScreenAndAudioSettingsButCannotBeRequested() async {
        await CLIProbe.inWorld { world in
            let settings = await CLIProbe.capture([
                "permissions", "settings", "applicationAudio", "--json",
            ])
            let request = await CLIProbe.capture([
                "permissions", "request", "applicationAudio",
            ])

            #expect(settings.code == 0)
            #expect(settings.object?["permission"] as? String == "applicationAudio")
            #expect(
                world.recordedURLs() == [ExtensionPermission.screenRecording.settingsURL!])
            #expect(request.code == ExitCodes.unavailable)
            #expect(request.stderr.contains("granted on first use"))
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func requestJSONReportsDispatchGrantAndSafeRelaunchPolicy() async {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)

            let result = await CLIProbe.capture([
                "permissions", "request", "screenRecording", "--json",
            ])

            #expect(result.code == 0)
            #expect(result.object?["permission"] as? String == "screenRecording")
            #expect(result.object?["requested"] as? Bool == true)
            #expect(result.object?["granted"] as? Bool == false)
            #expect(result.object?["relaunch"] as? String == "edith")
            #expect(result.object?["relaunchRequired"] as? Bool == false)
            #expect(
                world.postedNames()
                    == [
                        IPC.Name.grantScreenRecording.rawValue,
                        IPC.Name.requestPermissionsRefresh.rawValue,
                    ])
        }
    }
}

@Suite struct CLIPermissionProcessTests {
    @Test func shippedBinaryReadsPermissionMirrorOutsideARepository() throws {
        let suite = "CLIPermissionProcessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Permissions.calendarGranted)
        defaults.synchronize()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-permission-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_TEST_SHARED_DEFAULTS_SUITE"] = suite

        let plain = try CLIProcessProbe.run(
            ["permissions", "ls"], currentDirectory: outside, environment: environment)
        let json = try CLIProcessProbe.run(
            ["permissions", "ls", "--json"], currentDirectory: outside,
            environment: environment)
        let calendar = (json.object?["permissions"] as? [[String: Any]])?.first {
            $0["id"] as? String == "calendar"
        }

        #expect(plain.code == 0)
        #expect(plain.stdout.contains("calendar"))
        #expect(calendar?["granted"] as? Bool == true)
        #expect(plain.stderr.isEmpty)
        #expect(json.stderr.isEmpty)
    }
}
