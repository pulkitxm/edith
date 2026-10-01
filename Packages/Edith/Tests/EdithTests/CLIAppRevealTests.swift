import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIAppRevealTests {
    @Test func revealAsksTheMainWindowForTheSection() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": true, "section": "companion"] }
            let result = await CLIProbe.capture(["app", "reveal", "companion", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["section"] as? String == "companion")
            #expect(result.object?["tab"] is NSNull)
            #expect(world.postedNames() == [IPC.Name.requestReveal.rawValue])
            #expect(world.posted.first?.info["section"] as? String == "companion")
        }
    }

    @Test func aBareRevealJustBringsTheWindowUp() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": true, "section": "machines"] }
            let result = await CLIProbe.capture(["app", "reveal"])
            #expect(result.code == 0)
            #expect(result.stdout.contains("machines"))
            #expect(world.posted.first?.info["section"] == nil)
        }
    }

    @Test func aTabWithoutASectionIsAUsageError() async throws {
        await CLIProbe.inWorld { _ in
            CLIEnvironment.isMainAppRunning = { true }
            let result = await CLIProbe.capture(["app", "reveal", "--tab", "chat"])
            #expect(result.code == ExitCodes.usage)
            #expect(result.stderr.contains("needs a section"))
        }
    }

    @Test func revealPassesTheTabAlong() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": true, "section": "companion", "tab": "chat"] }
            let result = await CLIProbe.capture(
                ["app", "reveal", "companion", "--tab", "chat"])
            #expect(result.code == 0)
            #expect(result.stdout.contains("companion"))
            #expect(result.stdout.contains("chat"))
            #expect(world.posted.first?.info["tab"] as? String == "chat")
        }
    }

    @Test func aSectionTheAppRefusesIsNotFound() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": false, "error": "no section named nowhere"] }
            let result = await CLIProbe.capture(["app", "reveal", "nowhere"])
            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("no section named nowhere"))
        }
    }

    @Test func aRevealTheAppNeverAnswersIsDiagnosed() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.helperRunning(true)
            world.answers { _ in nil }
            let result = await CLIProbe.capture(["app", "reveal", "companion"])
            #expect(result.code == ExitCodes.unavailable)
        }
    }

    @Test func listPrintsTheSidebarSections() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in
                [
                    "ok": true,
                    "sections":
                        #"[{"id":"home","title":"Home"},{"id":"studio","title":"Studio"}]"#,
                ]
            }
            let result = await CLIProbe.capture(["app", "reveal", "--list", "--json"])
            #expect(result.code == 0)
            let sections = result.object?["sections"] as? [[String: Any]]
            #expect(sections?.map { $0["id"] as? String } == ["home", "studio"])
            #expect(world.posted.first?.info["list"] as? Bool == true)
        }
    }

    @Test func listRefusesASection() async {
        await CLIProbe.inWorld { _ in
            CLIEnvironment.isMainAppRunning = { true }
            let result = await CLIProbe.capture(["app", "reveal", "home", "--list"])
            #expect(result.code == ExitCodes.usage)
        }
    }

    @Test func spaceCommandsParseAndReportJSON() async throws {
        #expect(try EdRoot.parseAsRoot(["herdr", "space"]) is HerdrSpaceListCommand)
        #expect(try HerdrSpaceCLI.side("down") == "bottom")
        #expect(try HerdrSpaceCLI.side("UP") == "top")
        #expect(throws: CLIFailure.self) { try HerdrSpaceCLI.side("beside") }
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.herdrSpaceActionResult else { return nil }
                let requestID =
                    world.postedPayloads(for: IPC.Name.requestHerdrSpaceAction).last?["requestID"]
                    as? String ?? ""
                return [
                    "ok": true, "requestID": requestID, "message": "opened a terminal",
                    "windows": #"[{"id":"desk","title":"Desk","tabs":2,"panes":1}]"#,
                ]
            }
            let result = await CLIProbe.capture([
                "herdr", "space", "terminal", "--window", "desk", "--json",
            ])
            #expect(result.code == 0)
            let windows = result.object?["windows"] as? [[String: Any]]
            #expect(windows?.first?["id"] as? String == "desk")
            #expect(windows?.first?["tabs"] as? Int == 2)
            #expect(result.object?["message"] as? String == "opened a terminal")
            #expect(
                world.postedPayloads(for: IPC.Name.requestHerdrSpaceAction).last?["action"]
                    as? String == "terminal")
        }
    }

    @Test func revealNeedsTheMainWindow() async {
        let result = await CLIProbe.run(["app", "reveal", "companion"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("main window"))
    }

    @Test func snapshotListsTheFilesTheAppWrote() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in
                ["ok": true, "files": "/tmp/edith-snapshots/edith.png"]
            }
            let result = await CLIProbe.capture(["app", "snapshot", "--json"])
            #expect(result.code == 0)
            let files = result.object?["files"] as? [String]
            #expect(files == ["/tmp/edith-snapshots/edith.png"])
            #expect(world.postedNames() == [IPC.Name.requestWindowSnapshot.rawValue])
        }
    }

    @Test func snapshotExpandsTheTildeInTheDirectory() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": true, "files": "/x/edith.png"] }
            let result = await CLIProbe.capture(["app", "snapshot", "--dir", "~/shots"])
            #expect(result.code == 0)
            let sent = world.posted.first?.info["dir"] as? String
            #expect(sent?.hasPrefix("/") == true)
            #expect(sent?.contains("~") == false)
            #expect(sent?.hasSuffix("/shots") == true)
        }
    }

    @Test func aSnapshotTheAppCouldNotTakeFails() async throws {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { _ in ["ok": false, "error": "no visible window rendered"] }
            let result = await CLIProbe.capture(["app", "snapshot"])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stderr.contains("no visible window rendered"))
        }
    }

    @Test func bothActionsAreListed() async {
        let result = await CLIProbe.run(["app", "actions", "--json"])
        let names = (result.array as? [[String: Any]])?.compactMap { $0["action"] as? String }
        #expect(names?.contains("reveal") == true)
        #expect(names?.contains("snapshot") == true)
    }
}
