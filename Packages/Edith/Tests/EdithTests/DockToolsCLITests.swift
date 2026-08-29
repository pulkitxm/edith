import EdithKit
import Foundation
import Testing

@testable import EdithCLI

@Suite struct DockToolsCLITests {
    static func requestID(in world: CLIWorld) -> String {
        world.postedPayloads(for: IPC.Name.requestDockToolsOperation).last?[
            DockToolsIPC.requestIDKey] as? String ?? ""
    }

    static func reply(
        world: CLIWorld, status: String = "ok", payload: String = ""
    ) -> [AnyHashable: Any] {
        [
            DockToolsIPC.requestIDKey: requestID(in: world),
            DockToolsIPC.statusKey: status,
            DockToolsIPC.payloadKey: payload,
        ]
    }

    @Test func commandGroupIsRegisteredAtTheRoot() throws {
        let parsed = try EdRoot.parseAsRoot(["dock", "status"])
        #expect(CommandCrawler.name(of: type(of: parsed)) == "status")
    }

    @Test func statusWorksFromStoredPreferencesWithoutTheApp() async throws {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: AppStorageKeys.DockTools.enabled)
            world.shared.set("optionClick", forKey: AppStorageKeys.DockTools.previewMode)
            world.shared.set("cycleWindows", forKey: AppStorageKeys.DockTools.clickAction)
            world.shared.set(
                "com.example.two,com.example.one",
                forKey: AppStorageKeys.DockTools.excludedApps)

            let result = await CLIProbe.capture(["dock", "status", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["enabled"] as? Bool == true)
            #expect(result.object?["helperRunning"] as? Bool == false)
            #expect(result.object?["previewMode"] as? String == "optionClick")
            #expect(result.object?["clickAction"] as? String == "cycleWindows")
            #expect(
                result.object?["excludedApps"] as? [String]
                    == ["com.example.one", "com.example.two"])
        }
    }

    @Test func liveStatusUsesTheCorrelatedHelperReply() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            let preferences = DockToolsPreferences(
                enabled: true, previewMode: .hover, hoverDelay: 0.3,
                clickAction: .minimizeFrontWindow, greenButtonMaximizes: true,
                quitOnLastWindow: true, excludedBundleIdentifiers: [])
            let status = DockToolsStatus(
                preferences: preferences, helperRunning: true,
                accessibilityGranted: true, screenRecordingGranted: false)
            world.answers { name in
                name == IPC.Name.dockToolsOperationResult
                    ? Self.reply(world: world, payload: DockToolsIPC.encode(status)) : nil
            }

            let result = await CLIProbe.capture(["dock", "status", "--json"])

            #expect(result.code == 0)
            #expect(result.object?["ready"] as? Bool == true)
            #expect(result.object?["previewsAvailable"] as? Bool == false)
            #expect(result.object?["greenButtonMaximizes"] as? Bool == true)
            #expect(result.object?["quitOnLastWindow"] as? Bool == true)
            #expect(
                world.posted.first?.info[DockToolsIPC.operationKey] as? String == "status")
        }
    }

    @Test func windowsPrintsTheRuntimePayloadAsJSON() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            let windows = [
                DockToolsWindow(
                    id: "123:4", title: "Document", appName: "Example",
                    bundleIdentifier: "com.example.app", pid: 123, minimized: false)
            ]
            world.answers { name in
                name == IPC.Name.dockToolsOperationResult
                    ? Self.reply(world: world, payload: DockToolsIPC.encode(windows)) : nil
            }

            let result = await CLIProbe.capture([
                "dock", "windows", "com.example.app", "--json",
            ])

            #expect(result.code == 0)
            #expect(result.array?.count == 1)
            #expect((result.array?.first as? [String: Any])?["title"] as? String == "Document")
            #expect(
                world.posted.first?.info[DockToolsIPC.bundleIdentifierKey] as? String
                    == "com.example.app")
        }
    }

    @Test func actionsExplainWhenTheExtensionIsOff() async throws {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { name in
                name == IPC.Name.dockToolsOperationResult
                    ? Self.reply(world: world, status: "extensionOff") : nil
            }

            let result = await CLIProbe.capture(["dock", "show", "com.example.app"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("Dock Tools extension is off"))
            #expect(result.stderr.contains("extensions enable dockTools"))
        }
    }
}
