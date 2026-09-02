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

    @Test func bridgeRoutesWheelReportsWithoutChangingOtherInput() throws {
        var router = HerdrTerminalInputRouter()
        let hover = Data("\u{1B}[<35;11;6M".utf8)
        let click = Data("\u{1B}[<0;11;6M".utf8)
        let wheel = Data("\u{1B}[<92;11;6M".utf8)
        let commands = try router.commands(for: hover + click + wheel + Data("x".utf8))

        #expect(commands.count == 3)
        let leading = try object(commands[0])
        #expect(leading["type"] as? String == "terminal.input")
        #expect(
            Data(base64Encoded: try #require(leading["bytes"] as? String)) == hover + click)
        let scroll = try object(commands[1])
        #expect(scroll["type"] as? String == "terminal.scroll")
        #expect(scroll["direction"] as? String == "up")
        #expect(scroll["lines"] as? Int == 3)
        #expect(scroll["column"] as? Int == 10)
        #expect(scroll["row"] as? Int == 5)
        #expect(scroll["modifiers"] as? Int == 7)
        let trailing = try object(commands[2])
        #expect(Data(base64Encoded: try #require(trailing["bytes"] as? String)) == Data("x".utf8))
    }

    @Test func bridgeDropsFocusReportsWithoutChangingOtherInput() throws {
        var router = HerdrTerminalInputRouter()
        let focusIn = Data("\u{1B}[I".utf8)
        let focusOut = Data("\u{1B}[O".utf8)
        let escape = Data("\u{1B}".utf8)
        let commands = try router.commands(
            for: focusOut + Data("a".utf8) + focusIn + escape + Data("b".utf8) + focusOut)

        #expect(commands.count == 2)
        let leading = try object(commands[0])
        #expect(leading["type"] as? String == "terminal.input")
        #expect(Data(base64Encoded: try #require(leading["bytes"] as? String)) == Data("a".utf8))
        let trailing = try object(commands[1])
        #expect(
            Data(base64Encoded: try #require(trailing["bytes"] as? String))
                == escape + Data("b".utf8))
    }

    @Test func bridgeReassemblesWheelReportsAcrossReads() throws {
        var router = HerdrTerminalInputRouter()
        let first = try router.commands(for: Data("a\u{1B}[<65;12".utf8))
        #expect(first.count == 1)
        let firstObject = try object(first[0])
        #expect(
            Data(base64Encoded: try #require(firstObject["bytes"] as? String)) == Data("a".utf8))

        let second = try router.commands(for: Data(";7Mb".utf8))
        #expect(second.count == 2)
        let scroll = try object(second[0])
        #expect(scroll["direction"] as? String == "down")
        #expect(scroll["column"] as? Int == 11)
        #expect(scroll["row"] as? Int == 6)
        let trailing = try object(second[1])
        #expect(Data(base64Encoded: try #require(trailing["bytes"] as? String)) == Data("b".utf8))
    }

    private func object(_ command: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: command) as? [String: Any])
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
