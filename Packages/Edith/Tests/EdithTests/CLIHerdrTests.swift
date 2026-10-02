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

    @Test func bridgeRoutesWheelReportsAndDropsHover() throws {
        var router = HerdrTerminalInputRouter()
        let hover = Data("\u{1B}[<35;11;6M".utf8)
        let click = Data("\u{1B}[<0;11;6M".utf8)
        let drag = Data("\u{1B}[<32;12;6M".utf8)
        let wheel = Data("\u{1B}[<92;11;6M".utf8)
        let commands = try router.commands(
            for: hover + click + drag + hover + wheel + Data("x".utf8))

        #expect(commands.count == 3)
        let leading = try object(commands[0])
        #expect(leading["type"] as? String == "terminal.input")
        #expect(
            Data(base64Encoded: try #require(leading["bytes"] as? String)) == click + drag)
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

    @Test func scrollOnlyBridgeKeepsEveryPointerReportOutOfTheShell() throws {
        var router = HerdrTerminalInputRouter(mouse: .scroll)
        let hover = Data("\u{1B}[<35;103;2M".utf8)
        let press = Data("\u{1B}[<0;31;14M".utf8)
        let release = Data("\u{1B}[<0;31;14m".utf8)
        let wheel = Data("\u{1B}[<65;4;4M".utf8)
        let commands = try router.commands(
            for: Data("ls".utf8) + hover + press + release + wheel + Data("\r".utf8))

        #expect(commands.count == 3)
        #expect(
            Data(base64Encoded: try #require(try object(commands[0])["bytes"] as? String))
                == Data("ls".utf8))
        #expect(try object(commands[1])["type"] as? String == "terminal.scroll")
        #expect(
            Data(base64Encoded: try #require(try object(commands[2])["bytes"] as? String))
                == Data("\r".utf8))
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

    @Test(arguments: [
        "\u{1B}[<0;122;31M", "\u{1B}[<0;122;31m", "\u{1B}[<32;122;31M",
        "\u{1B}[<66;95;22M", "\u{1B}[<67;95;22M", "\u{1B}[I", "\u{1B}[O",
    ])
    func scrollOnlyBridgeDropsReportsAtEveryReadBoundary(report: String) throws {
        let bytes = Data(report.utf8)
        for split in 1..<bytes.count {
            var router = HerdrTerminalInputRouter(mouse: .scroll)
            let first = try router.commands(for: Data("before".utf8) + bytes.prefix(split))
            let second = try router.commands(for: bytes.dropFirst(split) + Data("after".utf8))
            let commands = first + second + (try router.finish())
            let input = try commands.reduce(into: Data()) { result, command in
                let encoded = try #require(try object(command)["bytes"] as? String)
                result.append(try #require(Data(base64Encoded: encoded)))
            }
            #expect(input == Data("beforeafter".utf8))
        }
    }

    @Test func bridgeReassemblesWheelReportsOneByteAtATime() throws {
        var router = HerdrTerminalInputRouter(mouse: .scroll)
        var commands: [Data] = []
        for byte in "\u{1B}[<65;123;32M".utf8 {
            commands += try router.commands(for: Data([byte]))
        }
        #expect(commands.count == 1)
        let scroll = try object(try #require(commands.first))
        #expect(scroll["type"] as? String == "terminal.scroll")
        #expect(scroll["direction"] as? String == "down")
        #expect(scroll["column"] as? Int == 122)
        #expect(scroll["row"] as? Int == 31)
    }

    @Test func standaloneEscapeIsDeliveredAfterThePrefixTimeout() throws {
        var router = HerdrTerminalInputRouter(mouse: .scroll)
        #expect(try router.commands(for: Data([0x1B])).isEmpty)
        #expect(router.hasPendingEscapePrefix)
        let commands = try router.flushEscapePrefix()
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        let encoded = try #require(try object(command)["bytes"] as? String)
        #expect(Data(base64Encoded: encoded) == Data([0x1B]))
        #expect(!router.hasPendingEscapePrefix)
    }

    @Test func aMouseReportIsNotFlushedIntoInputAtTimeoutOrEOF() throws {
        var router = HerdrTerminalInputRouter(mouse: .scroll)
        #expect(try router.commands(for: Data("\u{1B}[<0;122;".utf8)).isEmpty)
        #expect(!router.hasPendingEscapePrefix)
        #expect(try router.flushEscapePrefix().isEmpty)
        #expect(try router.finish().isEmpty)
    }

    @Test(arguments: ["\u{1B}[A", "\u{1B}[D", "\u{1B}[1;5C", "\u{1B}x"])
    func bridgePreservesSplitKeyboardSequences(sequence: String) throws {
        var router = HerdrTerminalInputRouter(mouse: .scroll)
        var input = Data()
        for byte in sequence.utf8 {
            for command in try router.commands(for: Data([byte])) {
                let encoded = try #require(try object(command)["bytes"] as? String)
                input.append(try #require(Data(base64Encoded: encoded)))
            }
        }
        #expect(input == Data(sequence.utf8))
    }

    @Test func inputTimeoutLeavesThePipeOpenAndReadable() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }
        #expect(
            try HerdrTerminalStream.read(from: pipe.fileHandleForReading, timeoutMilliseconds: 1)
                == nil)
        let input = Data("draft".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: input)
        #expect(
            try HerdrTerminalStream.read(from: pipe.fileHandleForReading, timeoutMilliseconds: 100)
                == input)
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
