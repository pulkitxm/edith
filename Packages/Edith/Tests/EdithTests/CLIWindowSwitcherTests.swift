import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIWindowSwitcherTests {
    @Test func listPrintsTheHelperWindowPayload() async throws {
        let windows = [
            WindowSwitcherWindow(
                id: "42:0", appName: "Notes", bundleIdentifier: "com.apple.Notes",
                title: "Plan", isMinimized: true, pid: 42)
        ]
        let result = await CLIProbe.runInWorld(["windows", "ls", "--json"]) { world in
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.windowSwitcherOperationResult,
                    let request = world.postedPayloads(
                        for: IPC.Name.requestWindowSwitcherOperation
                    ).last,
                    let requestID = request[WindowSwitcherIPC.requestIDKey] as? String
                else { return nil }
                return [
                    WindowSwitcherIPC.requestIDKey: requestID,
                    WindowSwitcherIPC.statusKey: "ok",
                    WindowSwitcherIPC.payloadKey: WindowSwitcherIPC.encode(windows),
                ]
            }
        }

        #expect(result.code == 0)
        let row = try #require(result.array?.first as? [String: Any])
        #expect(row["id"] as? String == "42:0")
        #expect(row["title"] as? String == "Plan")
        #expect(row["minimized"] as? Bool == true)
    }

    @Test func showReportsAnExtensionThatIsOff() async {
        let result = await CLIProbe.runInWorld(["windows", "show"]) { world in
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.windowSwitcherOperationResult,
                    let request = world.postedPayloads(
                        for: IPC.Name.requestWindowSwitcherOperation
                    ).last,
                    let requestID = request[WindowSwitcherIPC.requestIDKey] as? String
                else { return nil }
                return [
                    WindowSwitcherIPC.requestIDKey: requestID,
                    WindowSwitcherIPC.statusKey: "extensionOff",
                ]
            }
        }

        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("Window Switcher extension is off"))
    }

    @Test func activateSendsTheSelectedWindowID() async {
        let result = await CLIProbe.runInWorld(["windows", "activate", "77:2", "--json"]) {
            world in
            world.helperRunning(true)
            world.answers { name in
                guard name == IPC.Name.windowSwitcherOperationResult,
                    let request = world.postedPayloads(
                        for: IPC.Name.requestWindowSwitcherOperation
                    ).last,
                    let requestID = request[WindowSwitcherIPC.requestIDKey] as? String
                else { return nil }
                #expect(request[WindowSwitcherIPC.windowIDKey] as? String == "77:2")
                return [
                    WindowSwitcherIPC.requestIDKey: requestID,
                    WindowSwitcherIPC.statusKey: "ok",
                ]
            }
        }

        #expect(result.code == 0)
        #expect(result.object?["activated"] as? Bool == true)
    }
}
