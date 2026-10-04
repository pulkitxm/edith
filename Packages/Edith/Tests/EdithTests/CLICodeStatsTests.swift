import Foundation
import Testing

@testable import EdithAgent
@testable import EdithCLI
@testable import EdithKit

@Suite struct CLICodeStatsTests {
    @Test func settingsCommandsWriteTheSharedDefaultsTheAgentReads() async throws {
        try await CLIProbe.inWorld { world in
            let folder = await CLIProbe.capture(
                ["code-stats", "folder", world.sandbox.path, "--json"])
            #expect(folder.code == 0)
            let path = try #require(folder.object?["path"] as? String)
            #expect(folder.object?["changed"] as? Bool == true)
            #expect(CodeStatsPreferences.load(from: world.shared).folder == path)
            let missing = await CLIProbe.capture(
                ["code-stats", "folder", world.sandbox.appendingPathComponent("nope").path])
            #expect(missing.code == ExitCodes.notFound)

            let weekly = await CLIProbe.capture(
                ["code-stats", "schedule", "weekly", "--weekday", "6", "--hour", "22", "--json"])
            #expect(weekly.code == 0)
            #expect(weekly.object?["kind"] as? String == "weekly")
            #expect(
                CodeStatsPreferences.schedule(in: world.shared)
                    == .weekly(weekday: 6, hour: 22))
            let daily = await CLIProbe.capture(["code-stats", "schedule", "daily"])
            #expect(daily.code == 0)
            #expect(CodeStatsPreferences.schedule(in: world.shared) == .daily(hour: 22))
            for invalid in [
                ["code-stats", "schedule", "hourly"],
                ["code-stats", "schedule", "daily", "--hour", "24"],
                ["code-stats", "schedule", "weekly", "--weekday", "0"],
            ] {
                #expect(await CLIProbe.capture(invalid).code == ExitCodes.usage)
            }

            #expect(
                await CLIProbe.capture(["code-stats", "identity", "add", "you@example.com"]).code
                    == 0)
            let fragment = await CLIProbe.capture(
                ["code-stats", "identity", "add", "octocat", "--json"])
            #expect(fragment.object?["changed"] as? Bool == true)
            let list = await CLIProbe.capture(["code-stats", "identity", "--json"])
            #expect(list.object?["emails"] as? [String] == ["you@example.com"])
            #expect(list.object?["substrings"] as? [String] == ["octocat"])
            #expect(
                await CLIProbe.capture(["code-stats", "identity", "rm", "OCTOCAT"]).code == 0)
            let gone = await CLIProbe.capture(["code-stats", "identity", "remove", "octocat"])
            #expect(gone.code == ExitCodes.notFound)
            #expect(
                CodeStatsPreferences.identity(in: world.shared)
                    == CodeStatsIdentity(emails: ["you@example.com"]))
            #expect(
                world.postedNames().filter { $0 == IPC.Name.settingsChanged.rawValue }.count
                    == 6)
        }
    }

    @Test func agentCommandsReportUnavailableWithoutTouchingStdout() async {
        await CLIProbe.inWorld { _ in
            for command in ["status", "run", "cancel", "report", "authors"] {
                let result = await CLIProbe.capture(["code-stats", command, "--json"])
                #expect(result.code == ExitCodes.unavailable, "\(command)")
                #expect(result.stdout.isEmpty, "\(command)")
            }
            let range = await CLIProbe.capture(["code-stats", "report", "--range", "7d"])
            #expect(range.code == ExitCodes.usage)
        }
    }

    @Test func runStatusReportAndAuthorsDriveTheAgentWorkflow() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let remote = try await harness.remote("demo")
        let workflow = await harness.workflow(
            github: CodeStatsWorkflowGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/demo", cloneURL: remote.path)
            ]))
        let runtime = harness.runtime
        let tasks = harness.tasks
        try await CLIProbe.inWorld { _ in
            CodeStatsCLIEnvironment.client = {
                CodeStatsAgentClient { operation, payload, _ in
                    try await runtime.perform(operation: operation, payload: payload)
                }
            }
            CodeStatsCLIEnvironment.wait = { id, report in
                while true {
                    let status = try await tasks.status(id)
                    status.output.forEach { report($0.text) }
                    if status.snapshot.state.isTerminal { return status.result ?? Data() }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            let empty = await CLIProbe.capture(["code-stats", "report", "--json"])
            #expect(empty.code == ExitCodes.notFound)

            let run = await CLIProbe.capture(["code-stats", "run", "--wait", "--json"])
            #expect(run.code == 0)
            #expect(run.object?["outcome"] as? String == "completed")
            #expect(run.object?["repositories"] as? Int == 1)
            #expect(run.stderr.contains("Synced 1 of 1 repositories"))

            let status = await CLIProbe.capture(["code-stats", "--json"])
            #expect(status.code == 0)
            #expect(status.object?["folder"] as? String == harness.mirror.path)
            #expect(status.object?["running"] as? Bool == false)
            #expect(status.object?["login"] as? String == "octocat")
            let lastRun = status.object?["lastRun"] as? [String: Any]
            #expect(lastRun?["outcome"] as? String == "completed")
            let human = await CLIProbe.capture(["code-stats", "status"])
            #expect(human.stdout.contains("last run: completed"))

            let report = await CLIProbe.capture(
                ["code-stats", "report", "--range", "all", "--json"])
            #expect(report.code == 0)
            let totals = report.object?["totals"] as? [String: Any]
            #expect(totals?["commits"] as? Int == 1)
            #expect(report.object?["range"] as? String == "all")

            let authors = await CLIProbe.capture(["code-stats", "authors", "--json"])
            let first = (authors.array as? [[String: Any]])?.first
            #expect(first?["email"] as? String == "you@example.com")
            #expect(first?["countedAsYou"] as? Bool == true)

            let cancel = await CLIProbe.capture(["code-stats", "cancel"])
            #expect(cancel.code == 0)
            #expect(cancel.stdout.contains("no refresh is running"))
        }
        _ = workflow
    }
}
