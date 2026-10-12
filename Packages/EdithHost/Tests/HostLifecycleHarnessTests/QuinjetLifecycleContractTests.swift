import EdithExtensionSupport
import Foundation
import Testing
@testable import HostLifecycleHarness

@MainActor @Suite struct QuinjetLifecycleContractTests {
    @Test func directToolStreamDrivesOnlyItsAuthenticatedManagedAction() async throws {
        let worker = Worker()
        #expect(try await worker.verify() == 101)
        #expect(worker.commands.contains("quinjet.terminal.input"))
        #expect(worker.commands.contains("quinjet.terminal.resize"))
        #expect(worker.commands.filter { $0 == "quinjet.native.action" }.count == 1)
        #expect(worker.staleRejected)
        #expect(worker.tabs.count == 2)
        #expect(!worker.commands.contains("surface.perform"))
    }

    @Test func anEmptyReadBacksOffAndKeepsTheOwnedStream() async throws {
        let worker = Worker(mode: "empty-read")
        let started = ContinuousClock.now
        #expect(try await worker.verify() == 101)
        #expect(started.duration(to: .now) >= .milliseconds(50))
        #expect(worker.reads == 3)
    }

    @Test(arguments: [
        "parent", "group", "tty", "script", "script-hash", "birth", "executable", "argv",
        "pid-reuse", "stale-accepted", "stale-timeout", "offset", "exit", "raw-terminal",
        "false-action", "changed-generation", "missing-receipt", "live-tty",
        "late-script", "wrong-project", "wrong-command",
    ])
    func malformedOwnershipOrStreamCannotClaimSuccess(mode: String) async {
        let worker = Worker(mode: mode)
        await #expect(throws: (any Error).self) { try await worker.verify() }
    }

    @Test func processArgumentsAreBoundedAndReadOnlyTheDeclaredArgumentCount() throws {
        var count: Int32 = 3
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(
            Data("/usr/bin/python3\0\0python3\0/owned/bin/quinjet\0tui\0SECRET=foreign\0".utf8))
        #expect(
            try QuinjetLifecycleFixture.arguments(bytes) == [
                "python3", "/owned/bin/quinjet", "tui",
            ])
        #expect(throws: (any Error).self) {
            try QuinjetLifecycleFixture.arguments(Data(bytes.prefix(9)))
        }
        #expect(throws: (any Error).self) {
            try QuinjetLifecycleFixture.arguments(Data(repeating: 0, count: 65_537))
        }
    }

    @MainActor final class Worker {
        typealias Fixture = QuinjetLifecycleFixture
        let mode: String
        let tabID = UUID()
        let handle = Fixture.Handle(owner: "quinjet", id: UUID(), generation: UUID())
        let generation = UUID()
        var sequence: UInt64 = 0
        var tabs: [Fixture.Tab] = []
        var commands: [String] = []
        var reads = 0
        var processReads = 0
        var staleRejected = false
        var marker = ""

        init(mode: String = "valid") {
            self.mode = mode
            tabs = [Fixture.Tab(id: tabID, terminal: .init(handle: handle))]
        }

        func verify() async throws -> Int32 {
            try await Fixture.verify(
                invoke: invoke, workerPID: 100, script: "/owned/bin/quinjet",
                project: "/owned/synthetic-project", scriptSHA256: "hash",
                receipt: receipt, process: process,
                timeout: mode == "missing-receipt" ? .milliseconds(1) : .seconds(1))
        }

        func receipt() throws -> Data? {
            if mode == "missing-receipt" { return nil }
            return try JSONEncoder().encode(
                Fixture.Receipt(
                    pid: 101, birth: "10.20", parent: mode == "parent" ? 99 : 100,
                    group: mode == "group" ? 100 : 101, inputTerminal: mode != "tty",
                    executable: "/usr/bin/python3",
                    script: mode == "script" ? "/foreign" : "/owned/bin/quinjet",
                    scriptSHA256: mode == "script-hash" ? "foreign" : "hash", tabID: tabID))
        }

        func process(_ pid: Int32, _ parent: Int32) throws -> Fixture.Process {
            #expect(pid == 101)
            #expect(parent == 100)
            processReads += 1
            return Fixture.Process(
                pid: pid,
                birth: mode == "birth" || (mode == "pid-reuse" && processReads > 1)
                    ? "30.40" : "10.20",
                parent: parent, group: pid,
                executable: mode == "executable" ? "/foreign" : "/usr/bin/python3",
                inputTerminal: mode != "live-tty",
                arguments: mode == "late-script"
                    ? ["/usr/bin/python3", "/foreign", "--argument", "/owned/bin/quinjet"]
                    : [
                        "/usr/bin/python3", mode == "argv" ? "/foreign" : "/owned/bin/quinjet",
                        "--client", "edith", "-C",
                        mode == "wrong-project" ? "/foreign" : "/owned/synthetic-project",
                        mode == "wrong-command" ? "status" : "tui",
                    ])
        }

        func invoke(_ operation: String, _ data: Data) async throws -> Data {
            commands.append(operation)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if operation == "quinjet.ui.read" {
                sequence += 1
                return try JSONEncoder().encode(
                    Fixture.State(
                        owner: "quinjet",
                        generation: mode == "changed-generation" && tabs.count == 2
                            ? UUID() : generation,
                        sequence: sequence, tabs: tabs, selected: tabs.last!.id))
            }
            if operation == "quinjet.native.action" {
                #expect(Set(object.keys) == ["tabID", "action"])
                #expect(object["tabID"] as? String == tabID.uuidString)
                #expect(object["action"] as? String == "quinjet;open-new-tab")
                #expect(reads == (mode == "empty-read" ? 3 : 2))
                tabs.append(.init(id: UUID(), terminal: nil))
                return Data(
                    (mode == "false-action" ? "{\"accepted\":false}" : "{\"accepted\":true}").utf8)
            }
            let supplied = try #require(object["session"] as? [String: String])
            #expect(supplied["owner"] == "quinjet")
            #expect(supplied["id"] == handle.id.uuidString)
            if supplied["generation"] != handle.generation.uuidString {
                staleRejected = true
                if mode == "stale-accepted" { return Data("{}".utf8) }
                if mode == "stale-timeout" { throw ExtensionPeerError.timedOut }
                throw ExtensionPeerError.invalidRequest
            }
            if operation == "quinjet.terminal.input" {
                #expect(Set(object.keys) == ["session", "bytes"])
                let encoded = try #require(object["bytes"] as? String)
                let bytes = try #require(Data(base64Encoded: encoded))
                marker = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
                return Data("{}".utf8)
            }
            if operation == "quinjet.terminal.resize" {
                #expect(
                    Set(object.keys) == ["session", "columns", "rows", "pixelWidth", "pixelHeight"])
                return Data("{}".utf8)
            }
            #expect(operation == "quinjet.terminal.read")
            reads += 1
            let offset = try #require(object["offset"] as? UInt64)
            if mode == "empty-read", reads == 1 {
                return try JSONEncoder().encode(
                    Fixture.Output(
                        bytes: Data(), nextOffset: offset, exitCode: nil, canonical: true,
                        echo: true))
            }
            let bytes =
                reads == (mode == "empty-read" ? 2 : 1)
                ? Data("\u{1B}]6973;quinjet;".utf8)
                : Data(("open-new-tab\u{7}\r\nsynthetic-input:" + marker + "\r\n").utf8)
            return try JSONEncoder().encode(
                Fixture.Output(
                    bytes: bytes,
                    nextOffset: offset + UInt64(bytes.count) + (mode == "offset" ? 1 : 0),
                    exitCode: mode == "exit" ? 0 : nil, canonical: mode != "raw-terminal",
                    echo: true))
        }
    }
}
