import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIHerdrTests {
    @Test func listingWithoutHerdrIsStillSuccess() async {
        let result = await CLIProbe.run(["herdr", "ls", "--json"])
        #expect(result.code == 0)
        let object = result.object
        #expect(object?["hosts"] is [Any])
        #expect(object?["agents"] is [Any])
        let hosts = object?["hosts"] as? [[String: Any]] ?? []
        #expect(hosts.contains { $0["id"] as? String == "local" })
        for host in hosts {
            #expect(Set(host.keys) == ["error", "herdr", "id", "local", "name"])
            if let error = host["error"] as? String {
                #expect(!error.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
            }
        }
        let agents = object?["agents"] as? [[String: Any]] ?? []
        let expected: Set<String> = [
            "command", "cwd", "id", "kind", "local", "machine", "machineName", "pane",
            "session", "status", "title", "workspace",
        ]
        for agent in agents {
            #expect(Set(agent.keys) == expected)
        }
    }

    @Test func anUnknownMachineIsNotFound() async {
        let result = await CLIProbe.run(["herdr", "ls", "--machine", "nowhere-at-all", "--json"])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stdout.isEmpty)
        #expect(
            result.stderr.contains("no machine named")
                || result.stderr.contains("no machines are configured"))
    }

    @Test func localIsThisMacRatherThanAMachineName() async {
        let result = await CLIProbe.run(["herdr", "ls", "--machine", "local", "--json"])
        #expect(result.code == 0)
        let hosts = result.object?["hosts"] as? [[String: Any]] ?? []
        #expect(hosts.map { $0["id"] as? String } == ["local"])
        #expect(hosts.first?["local"] as? Bool == true)
    }

    @Test func aMissingPaneIsNotFound() async {
        let result = await CLIProbe.run([
            "herdr", "command", "nowhere-at-all", "--machine", "local", "--json",
        ])
        #expect(result.code == ExitCodes.notFound)
        #expect(result.stdout.isEmpty)
    }
}
