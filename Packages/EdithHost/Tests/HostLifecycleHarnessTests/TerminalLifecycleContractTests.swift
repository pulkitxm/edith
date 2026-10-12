import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing
@testable import HostLifecycleHarness

@MainActor @Suite struct TerminalLifecycleContractTests {
    @Test func currentGenerationAndSyntheticBytesAreVerifiedWithoutNavigation() async throws {
        let worker = Worker()
        let children = try await TerminalLifecycleFixture.verify(
            invoke: worker.invoke, children: { [101, 102] })
        #expect(children == [101, 102])
        #expect(worker.commands.filter { $0 == "terminal.open" }.count == 2)
        #expect(worker.commands.contains("terminal.input"))
        #expect(worker.commands.contains("terminal.read"))
        #expect(worker.commands.contains("surface.snapshot"))
        #expect(!worker.commands.contains("surface.perform"))
        #expect(!worker.commands.contains("terminal.status"))
        #expect(!worker.commands.contains("terminal.sessions"))
        #expect(worker.rejectedGenerations == 1)
        #expect(worker.selectedGenerations == [worker.sessions[0].generation])
    }

    @Test func obsoleteOpenReplyIsRejectedInsteadOfClaimingAStartedSession() {
        #expect(throws: (any Error).self) {
            try TerminalLifecycleFixture.decodeSnapshot(
                JSONSerialization.data(withJSONObject: ["opened": true, "id": UUID().uuidString]))
        }
    }

    @Test(arguments: ["generation", "duplicate", "selected", "title", "directory", "boolean"])
    func malformedSnapshotCannotPass(mode: String) throws {
        let worker = Worker()
        worker.addSession()
        var value = try #require(
            try JSONSerialization.jsonObject(with: worker.snapshot()) as? [String: Any])
        var sessions = try #require(value["sessions"] as? [[String: Any]])
        switch mode {
        case "generation": sessions[0]["generation"] = "foreign"
        case "duplicate": sessions.append(sessions[0])
        case "selected": sessions[0]["selected"] = false
        case "title": sessions[0]["title"] = String(repeating: "x", count: 513)
        case "directory": sessions[0]["directory"] = "owned\u{0}foreign"
        default: sessions[0]["running"] = "true"
        }
        value["sessions"] = sessions
        #expect(throws: (any Error).self) {
            try TerminalLifecycleFixture.decodeSnapshot(
                JSONSerialization.data(withJSONObject: value))
        }
    }

    @Test(arguments: [
        "selected-generation", "read-offset", "read-exit", "stale-success",
        "stale-timeout", "stale-cancelled", "stale-foreign-rejection",
    ])
    func invalidRepliesCannotPassTheStreamAndOwnershipProof(mode: String) async {
        let worker = Worker(mode: mode)
        await #expect(throws: (any Error).self) {
            try await TerminalLifecycleFixture.verify(
                invoke: worker.invoke, children: { [101, 102] })
        }
    }

    @MainActor final class Worker {
        typealias Session = TerminalLifecycleFixture.Session
        var sessions: [Session] = []
        var commands: [String] = []
        var selectedGenerations: [UUID] = []
        var rejectedGenerations = 0
        var bytes = Data()
        let mode: String

        init(mode: String = "valid") { self.mode = mode }

        func addSession() {
            sessions = sessions.map {
                Session(
                    id: $0.id, generation: $0.generation, title: $0.title,
                    directory: $0.directory, running: true, selected: false, error: nil)
            }
            sessions.append(
                Session(
                    id: UUID(), generation: UUID(), title: "Synthetic shell",
                    directory: "/owned/fixture", running: true, selected: true, error: nil))
        }

        func snapshot() throws -> Data {
            try JSONEncoder().encode(
                TerminalLifecycleFixture.Snapshot(sessions: sessions, broadcast: false))
        }

        func invoke(_ command: String, _ payload: Data) async throws -> Data {
            commands.append(command)
            let input = try #require(
                try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            switch command {
            case "terminal.open":
                #expect(input.isEmpty)
                addSession()
            case "terminal.snapshot":
                guard input.isEmpty else { throw ExtensionPeerError.invalidRequest }
            case "terminal.select":
                guard let id = input["id"] as? String,
                    let generation = input["generation"] as? String,
                    let owned = sessions.first(where: { $0.id.uuidString == id })
                else { throw ExtensionPeerError.invalidRequest }
                guard owned.generation.uuidString == generation else {
                    rejectedGenerations += 1
                    if mode == "stale-success" { return try snapshot() }
                    if mode == "stale-timeout" { throw HostWorkerError.timedOut }
                    if mode == "stale-cancelled" { throw CancellationError() }
                    if mode == "stale-foreign-rejection" {
                        throw ExtensionPeerError.rejected("foreign")
                    }
                    throw ExtensionPeerError.invalidRequest
                }
                selectedGenerations.append(owned.generation)
                if mode == "selected-generation" {
                    sessions[0] = Session(
                        id: owned.id, generation: UUID(), title: owned.title,
                        directory: owned.directory, running: true,
                        selected: true, error: nil)
                }
            case "surface.snapshot":
                _ = try SurfaceSnapshotRequest.decode(payload, providerID: "terminal")
                return try SurfaceSnapshot(
                    providerID: "terminal",
                    metrics: [
                        .init("sessions", "Sessions", "2"), .init("running", "Running", "2"),
                    ],
                    rows: sessions.map {
                        SurfaceDataRow($0.id.uuidString, title: $0.title, value: "Running")
                    }
                ).encoded()
            case "terminal.resize", "terminal.input", "terminal.read":
                let request = try #require(input["session"] as? [String: String])
                #expect(
                    request == [
                        "id": sessions[0].id.uuidString,
                        "generation": sessions[0].generation.uuidString,
                    ])
                if command == "terminal.input" {
                    let encoded = try #require(input["bytes"] as? String)
                    let supplied = try #require(Data(base64Encoded: encoded))
                    let parts = String(decoding: supplied, as: UTF8.self).components(
                        separatedBy: "'")
                    #expect(parts.count == 7)
                    bytes = Data(("terminal-fixture-" + parts[5] + "\r\n").utf8)
                } else if command == "terminal.read" {
                    #expect(input["offset"] as? Int == 0)
                    return try JSONEncoder().encode(
                        TerminalLifecycleFixture.Output(
                            bytes: bytes,
                            nextOffset: UInt64(bytes.count) + (mode == "read-offset" ? 1 : 0),
                            exitCode: mode == "read-exit" ? 9 : nil, canonical: false, echo: false))
                }
            case "terminal.broadcast":
                guard input["command"] as? String == "true" else {
                    throw ExtensionPeerError.invalidRequest
                }
                return try JSONSerialization.data(withJSONObject: ["sent": 2, "unavailable": 0])
            default: throw ExtensionPeerError.invalidRequest
            }
            return try snapshot()
        }
    }
}
