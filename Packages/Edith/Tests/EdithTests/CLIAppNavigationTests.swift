import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIAppNavigationTests {
    @Test func routePrintsTheSelection() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in
                ["ok": true, "route": "companion/chat", "canGoBack": true, "canGoForward": false]
            }
            let result = await CLIProbe.capture(["app", "route", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["route"] as? String == "companion/chat")
            #expect(result.object?["canGoBack"] as? Bool == true)
            #expect(result.object?["canGoForward"] as? Bool == false)
            #expect(world.postedNames() == [IPC.Name.requestNavigation.rawValue])
            #expect(world.posted.first?.info["action"] as? String == "route")
            #expect(world.posted.first?.info["route"] == nil)
        }
    }

    @Test func navigateSendsTheRouteAndDoesNotAskToOpen() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in
                ["ok": true, "route": "docs", "canGoBack": true, "canGoForward": false]
            }
            let result = await CLIProbe.capture(["app", "navigate", "docs"])
            #expect(result.code == 0)
            #expect(result.stdout.contains("docs"))
            #expect(world.postedNames() == [IPC.Name.requestNavigation.rawValue])
            #expect(world.posted.first?.info["action"] as? String == "navigate")
            #expect(world.posted.first?.info["route"] as? String == "docs")
            #expect(world.postedNames().contains(IPC.Name.openPanel.rawValue) == false)
            #expect(world.postedNames().contains(IPC.Name.requestReveal.rawValue) == false)
        }
    }

    @Test func aMalformedRouteIsUsage() async {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            let result = await CLIProbe.capture(["app", "navigate", "docs//page"])
            #expect(result.code == ExitCodes.usage)
            #expect(result.stderr.contains("malformed"))
            #expect(world.posted.isEmpty)
        }
    }

    @Test func backAndForwardWalkTheReply() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.navigationResult else { return nil }
                return ["ok": true, "route": "home", "canGoBack": false, "canGoForward": true]
            }
            let back = await CLIProbe.capture(["app", "back", "--json"])
            #expect(back.code == 0)
            #expect(back.object?["route"] as? String == "home")
            #expect(world.posted.first?.info["action"] as? String == "back")
            let forward = await CLIProbe.capture(["app", "forward"])
            #expect(forward.code == 0)
            #expect(forward.stdout.contains("home"))
            #expect(world.posted.last?.info["action"] as? String == "forward")
        }
    }

    @Test func nothingToGoBackToFails() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": false, "error": "nothing to go back to"] }
            let result = await CLIProbe.capture(["app", "back"])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stderr.contains("nothing to go back to"))
        }
    }

    @Test func routeNeedsTheMainWindow() async {
        let result = await CLIProbe.run(["app", "route"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("main window"))
    }

    @Test func revealAcceptsAFullRoute() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in
                ["ok": true, "section": "companion", "tab": "chat", "route": "companion/chat"]
            }
            let result = await CLIProbe.capture(["app", "reveal", "companion/chat", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["route"] as? String == "companion/chat")
            #expect(result.object?["section"] as? String == "companion")
            #expect(world.posted.first?.info["section"] as? String == "companion/chat")
            #expect(world.postedNames() == [IPC.Name.requestReveal.rawValue])
        }
    }
}
