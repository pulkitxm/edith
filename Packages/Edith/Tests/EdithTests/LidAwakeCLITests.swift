import EdithKit
import Foundation
import Testing

@testable import EdithCLI

@Suite struct LidAwakeCLITests {
    static func liveReply(
        active: Bool, extensionEnabled: Bool = true,
        session: LidAwakeSession = .indefinite, requestID: String? = nil
    ) -> [AnyHashable: Any] {
        var result: [AnyHashable: Any] = [
            LidAwakeIPC.okKey: true,
            "extensionEnabled": extensionEnabled,
            "active": active,
            "requestedActive": active,
            "applying": false,
            "batterySuspended": false,
            "session": session.rawValue,
            "batteryThreshold": 20,
            "restoreOnQuit": true,
            "helperStatus": "enabled",
            "appRunning": true,
        ]
        if let requestID { result[LidAwakeIPC.requestIDKey] = requestID }
        return result
    }

    static func requestID(in world: CLIWorld) -> String? {
        world.postedPayloads(for: IPC.Name.requestLidAwakeAction).last?[
            LidAwakeIPC.requestIDKey] as? String
    }

    @Test func commandGroupIsRegisteredAtTheRoot() throws {
        let parsed = try EdRoot.parseAsRoot(["lid-awake", "on"])
        #expect(CommandCrawler.name(of: type(of: parsed)) == "on")
    }

    @Test func durationPresetsMapToSessions() throws {
        #expect(try LidAwakeCLI.session(duration: nil, untilLidReopens: false) == .indefinite)
        #expect(try LidAwakeCLI.session(duration: "15m", untilLidReopens: false) == .fifteenMinutes)
        #expect(
            try LidAwakeCLI.session(duration: "30min", untilLidReopens: false) == .thirtyMinutes)
        #expect(try LidAwakeCLI.session(duration: "1h", untilLidReopens: false) == .oneHour)
        #expect(try LidAwakeCLI.session(duration: "120m", untilLidReopens: false) == .twoHours)
        #expect(try LidAwakeCLI.session(duration: nil, untilLidReopens: true) == .untilLidReopens)
    }

    @Test func conflictingAndUnknownSessionsFailBeforePosting() {
        #expect(throws: CLIFailure.self) {
            try LidAwakeCLI.session(duration: "30m", untilLidReopens: true)
        }
        #expect(throws: CLIFailure.self) {
            try LidAwakeCLI.session(duration: "45m", untilLidReopens: false)
        }
    }

    @Test func statusWorksWithoutTheAppFromStoredState() async throws {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: LidAwakeState.enabledKey)
            world.shared.set(true, forKey: LidAwakeState.activeKey)
            world.shared.set(LidAwakeSession.oneHour.rawValue, forKey: LidAwakeState.sessionKey)
            world.shared.set(30, forKey: LidAwakeState.batteryThresholdKey)
            let result = await CLIProbe.capture(["lid-awake", "status", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["active"] as? Bool == true)
            #expect(result.object?["session"] as? String == LidAwakeSession.oneHour.rawValue)
            #expect(result.object?["batteryThreshold"] as? Int == 30)
            #expect(result.object?["appRunning"] as? Bool == false)
            #expect(result.object?["remainingSeconds"] is NSNull)
        }
    }

    @Test func bareCommandCanEmitStatusAsJSON() async {
        let result = await CLIProbe.run(["lid-awake", "--json"])
        #expect(result.code == 0)
        #expect(result.object?["active"] as? Bool == false)
        #expect(result.object?["appRunning"] as? Bool == false)
    }

    @Test func offlineStatusPreservesRawOrphanedActiveState() async throws {
        await CLIProbe.inWorld { world in
            world.shared.set(false, forKey: LidAwakeState.enabledKey)
            world.shared.set(true, forKey: LidAwakeState.activeKey)

            let result = await CLIProbe.capture(["lid-awake", "status", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["extensionEnabled"] as? Bool == false)
            #expect(result.object?["active"] as? Bool == true)
        }
    }

    @Test func onNeedsTheMenuBarApp() async {
        let result = await CLIProbe.run(["lid-awake", "on"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("menu bar app"))
    }

    @Test func onPostsTheChosenSessionAndReportsLiveState() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { name in
                name == IPC.Name.lidAwakeActionResult
                    ? Self.liveReply(
                        active: true, session: .thirtyMinutes,
                        requestID: Self.requestID(in: world)) : nil
            }
            let result = await CLIProbe.capture([
                "lid-awake", "on", "--for", "30m", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["active"] as? Bool == true)
            #expect(result.object?["session"] as? String == LidAwakeSession.thirtyMinutes.rawValue)
            #expect(world.postedNames() == [IPC.Name.requestLidAwakeAction.rawValue])
            #expect(world.posted.first?.info[LidAwakeIPC.actionKey] as? String == "on")
            #expect(
                world.posted.first?.info[LidAwakeIPC.sessionKey] as? String
                    == LidAwakeSession.thirtyMinutes.rawValue)
            #expect(
                UUID(
                    uuidString: world.posted.first?.info[LidAwakeIPC.requestIDKey] as? String ?? "")
                    != nil)
            #expect(
                (world.posted.first?.info[LidAwakeIPC.deadlineKey] as? TimeInterval ?? 0)
                    > Date().timeIntervalSince1970)
        }
    }

    @Test func untilLidReopensIsSentAsItsOwnSession() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { _ in
                Self.liveReply(
                    active: true, session: .untilLidReopens,
                    requestID: Self.requestID(in: world))
            }
            let result = await CLIProbe.capture([
                "lid-awake", "on", "--until-lid-reopens",
            ])
            #expect(result.code == 0)
            #expect(
                world.posted.first?.info[LidAwakeIPC.sessionKey] as? String
                    == LidAwakeSession.untilLidReopens.rawValue)
        }
    }

    @Test func offWaitsForTheRuntimeResult() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { _ in
                Self.liveReply(active: false, requestID: Self.requestID(in: world))
            }
            let result = await CLIProbe.capture(["lid-awake", "off", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["active"] as? Bool == false)
            #expect(world.posted.first?.info[LidAwakeIPC.actionKey] as? String == "off")
        }
    }

    @Test func runtimeFailuresReachStderrAndExitOne() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { _ in
                [
                    LidAwakeIPC.okKey: false,
                    LidAwakeIPC.errorKey: "pmset refused",
                    LidAwakeIPC.requestIDKey: Self.requestID(in: world) ?? "",
                ]
            }
            let result = await CLIProbe.capture(["lid-awake", "on"])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stderr.contains("pmset refused"))
        }
    }

    @Test func extensionDisableWaitsForCorrelatedSafetyRestoration() async throws {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: LidAwakeState.enabledKey)
            world.shared.set(true, forKey: LidAwakeState.activeKey)
            world.helperRunning(true)
            world.answers { _ in
                guard
                    world.postedPayloads(for: IPC.Name.requestLidAwakeAction).last?[
                        LidAwakeIPC.actionKey] as? String
                        == LidAwakeIPC.Action.disableExtension.rawValue
                else { return nil }
                world.shared.set(false, forKey: LidAwakeState.enabledKey)
                world.shared.set(false, forKey: LidAwakeState.activeKey)
                return Self.liveReply(
                    active: false, extensionEnabled: false,
                    requestID: Self.requestID(in: world))
            }

            let result = await CLIProbe.capture([
                "extensions", "disable", "lidAwake", "--json",
            ])

            #expect(result.code == 0)
            #expect(result.object?["enabled"] as? Bool == false)
            #expect(!world.shared.bool(forKey: LidAwakeState.enabledKey))
            #expect(
                world.posted.first?.info[LidAwakeIPC.actionKey] as? String
                    == LidAwakeIPC.Action.disableExtension.rawValue)
        }
    }

    @Test func extensionDisableRefusesUnsafeOfflineMutation() async throws {
        await CLIProbe.inWorld { world in
            world.shared.set(false, forKey: LidAwakeState.enabledKey)
            world.shared.set(true, forKey: LidAwakeState.activeKey)

            let result = await CLIProbe.capture([
                "extensions", "disable", "lidAwake", "--json",
            ])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("normal sleep can be restored"))
            #expect(!world.shared.bool(forKey: LidAwakeState.enabledKey))
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func batteryThresholdIsConfiguredLive() async throws {
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture(["lid-awake", "battery", "25", "--json"])
            #expect(result.code == 0)
            #expect(world.shared.integer(forKey: LidAwakeState.batteryThresholdKey) == 25)
            #expect(result.object?["batteryThreshold"] as? Int == 25)
            #expect(world.postedNames() == [IPC.Name.settingsChanged.rawValue])
        }
    }

    @Test func batteryCanBeDisabledAndRejectsInvalidValues() async {
        let off = await CLIProbe.run(["lid-awake", "battery", "off", "--json"])
        #expect(off.code == 0)
        #expect(off.object?["batteryThreshold"] as? Int == 0)
        let invalid = await CLIProbe.run(["lid-awake", "battery", "101"])
        #expect(invalid.code == ExitCodes.failure)
    }

    @Test func restoreOnQuitIsConfiguredLive() async throws {
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture([
                "lid-awake", "restore-on-quit", "false", "--json",
            ])
            #expect(result.code == 0)
            #expect(world.shared.bool(forKey: LidAwakeState.restoreOnQuitKey) == false)
            #expect(result.object?["restoreOnQuit"] as? Bool == false)
            #expect(world.postedNames() == [IPC.Name.settingsChanged.rawValue])
        }
    }

    @Test func allLidAwakeSettingsAreInTheConfigCatalog() {
        for key in [
            LidAwakeState.enabledKey,
            LidAwakeState.activeKey,
            LidAwakeState.restoreOnQuitKey,
            LidAwakeState.sessionKey,
            LidAwakeState.batteryThresholdKey,
        ] {
            #expect(ConfigCatalog.definition(for: key) != nil, "missing \(key)")
        }
        #expect(ConfigCatalog.definition(for: LidAwakeState.activeKey)?.readOnly == true)
    }
}
