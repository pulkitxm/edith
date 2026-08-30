import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

private final class HerdrPipeReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func read() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite struct CLIHerdrTests {
    @Test func bridgeReadsAFrameWithoutWaitingForThePipeToClose() throws {
        let pipe = Pipe()
        let result = HerdrPipeReadBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.set(HerdrTerminalStream.read(from: pipe.fileHandleForReading))
            finished.signal()
        }

        let frame = Data("frame\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: frame)

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(result.read() == frame)
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }

    @Test func listingWithoutHerdrIsStillSuccess() async {
        let result = await CLIProbe.run(["herdr", "ls", "--json"])
        #expect(result.code == 0)
        let object = result.object
        #expect(object?["hosts"] is [Any])
        #expect(object?["agents"] is [Any])
        let hosts = object?["hosts"] as? [[String: Any]] ?? []
        #expect(hosts.contains { $0["id"] as? String == "local" })
        for host in hosts {
            #expect(
                Set(host.keys) == ["error", "herdr", "id", "local", "name", "reachable"])
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
