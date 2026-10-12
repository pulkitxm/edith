import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@Suite struct UsageMachinesPeerTests {
    actor Transport {
        let data: Data
        let corrupt: Bool
        var releases = 0
        init(data: Data, corrupt: Bool = false) { self.data = data; self.corrupt = corrupt }
        func invoke(_ command: String, payload: Data) throws -> Data {
            switch command {
            case "machines.usage.collect":
                return try JSONEncoder().encode(
                    UsageMachinesPeer.Receipt(
                        collectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        byteCount: data.count,
                        sha256: corrupt
                            ? String(repeating: "0", count: 64) : UsageMachinesPeer.hash(data),
                        generatedAt: "2026-10-09T12:00:00Z"))
            case "machines.usage.result":
                let request = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
                let offset = request["offset"] as! Int
                let end = min(data.count, offset + 262_144)
                return try JSONEncoder().encode(
                    UsageMachinesPeer.Chunk(
                        offset: offset, data: data.subdata(in: offset..<end),
                        finished: end == data.count))
            case "machines.usage.cancel": releases += 1; return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
    }

    @Test func chunkedResultIsValidatedAndReleasedBeforeReturning() async throws {
        let data = try fixture()
        let transport = Transport(data: data)
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        #expect(try await peer.collect(machineID: UUID(), force: false) == data)
        #expect(await transport.releases == 1)
    }

    @Test func checksumFailureAndInactivePeersCannotPublishData() async throws {
        let transport = Transport(data: try fixture(), corrupt: true)
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await peer.collect(machineID: UUID(), force: false)
        }
        #expect(await transport.releases == 1)
        let inactive = UsageMachinesPeer(
            active: { false },
            invoke: { _, _ in
                Issue.record("Inactive peer invoked"); return Data()
            })
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await inactive.collect(machineID: UUID(), force: false)
        }
    }

    @Test func remoteSourcesAreBoundToRegistryMachineIdentity() throws {
        let machine = Machine(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Sample machine",
            host: "sample.invalid")
        let data = try UsageMachinesPeer.canonicalized(fixture(), machine: machine)
        #expect(UsageHistory.isValidDocument(data))
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(
            value["sources"] as? [String] == ["machine:22222222-2222-2222-2222-222222222222:codex"])
    }

    @Test func progressForwardsExactBytesBeforeReadingDistinctNativeResultReceipt() async throws {
        let data = try await nativeDocument()
        let output = UsageMachinesProgressOutput()
        let transport = UsageMachinesProgressTransport(data: data, output: output)
        let first = UsageMachinesPeer.ProgressChunk(
            sequence: 0, channel: "stderr", data: Data([0, 255, 195, 40]))
        let second = UsageMachinesPeer.ProgressChunk(
            sequence: 1, channel: "stdout", data: Data("fixture bytes\n".utf8))
        await transport.setFrames([
            transport.frame(sequence: 0, next: 1, chunks: [first]),
            transport.frame(
                sequence: 1, next: 2, chunks: [second], state: .completed,
                receipt: transport.receipt),
        ])
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        let result = try await peer.collect(machineID: UUID(), force: true) {
            output.append($0, error: $1)
        }
        #expect(result == data && UsageHistory.isValidDocument(result))
        #expect(output.snapshot.map(\.data) == [first.data, second.data])
        #expect(output.snapshot.map(\.error) == [true, false])
        #expect(await transport.sequences == [0, 1])
        #expect(await transport.released == [transport.resultID, transport.jobID])
        #expect(await transport.resultReads == 1)
    }

    @Test(arguments: UsageMachinesInvalidProgress.allCases)
    func invalidProgressCannotForwardBytesOrReadAResult(mode: UsageMachinesInvalidProgress)
        async throws
    {
        let data = try await nativeDocument()
        let output = UsageMachinesProgressOutput()
        let transport = UsageMachinesProgressTransport(data: data, output: output)
        var id = transport.jobID
        var sequence: UInt64 = 0
        var next: UInt64 = 1
        var chunkSequence: UInt64 = 0
        var channel = "stderr"
        var bytes = Data([42])
        var state = UsageMachinesPeer.ProgressState.running
        var receipt: UsageMachinesPeer.Receipt?
        var error: String?
        switch mode {
        case .foreignJob: id = UUID()
        case .wrongSequence: sequence = 1
        case .wrongNext: next = 2
        case .wrongChunk: chunkSequence = 1
        case .badChannel: channel = "other"
        case .emptyChunk: bytes = Data()
        case .oversizedChunk: bytes = Data(repeating: 42, count: 65_537)
        case .earlyReceipt: receipt = await transport.receipt
        case .missingReceipt: state = .completed
        case .failed: state = .failed; error = "fixture failure"
        case .overflow: state = .overflow; error = "fixture unread capacity exceeded"
        case .cancelled: state = .cancelled
        }
        await transport.setFrames([
            UsageMachinesPeer.ProgressFrame(
                collectionID: id, sequence: sequence, nextSequence: next,
                chunks: [.init(sequence: chunkSequence, channel: channel, data: bytes)],
                state: state, receipt: receipt, error: error)
        ])
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        await #expect(throws: ExtensionPeerError.self) {
            try await peer.collect(machineID: UUID(), force: true) { output.append($0, error: $1) }
        }
        if mode == .failed || mode == .overflow || mode == .cancelled {
            #expect(output.snapshot.map(\.data) == [bytes])
        } else {
            #expect(output.snapshot.isEmpty)
        }
        #expect(await transport.resultReads == 0)
        #expect(await transport.released == [transport.jobID])
    }

    @Test(arguments: [false, true])
    func cancelledPollOrRejectedOutputReleasesTheProgressJob(rejectOutput: Bool) async throws {
        let output = UsageMachinesProgressOutput()
        let transport = UsageMachinesProgressTransport(
            data: try await nativeDocument(), output: output)
        if rejectOutput {
            await transport.setFrames([
                transport.frame(
                    sequence: 0, next: 1,
                    chunks: [.init(sequence: 0, channel: "stderr", data: Data([42]))])
            ])
        } else {
            await transport.suspendPoll()
        }
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        let operation = Task {
            try await peer.collect(machineID: UUID(), force: true) { _, _ in
                throw UsageMachinesOutputFailure.rejected
            }
        }
        if rejectOutput {
            await #expect(throws: UsageMachinesOutputFailure.self) { try await operation.value }
        } else {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await !transport.polling && ContinuousClock.now < deadline { await Task.yield() }
            try #require(await transport.polling)
            operation.cancel()
            await #expect(throws: CancellationError.self) { try await operation.value }
        }
        #expect(await transport.released == [transport.jobID])
        #expect(await transport.resultReads == 0)
    }

    @Test func withdrawnPeerAndExpiredDeadlineCannotPublishProgress() async throws {
        let output = UsageMachinesProgressOutput()
        let transport = UsageMachinesProgressTransport(
            data: try await nativeDocument(), output: output)
        await transport.setFrames([
            transport.frame(
                sequence: 0, next: 1,
                chunks: [.init(sequence: 0, channel: "stderr", data: Data([42]))])
        ])
        await transport.withdrawAfterReply()
        let peer = UsageMachinesPeer(
            active: { await transport.active },
            invoke: { try await transport.invoke($0, payload: $1) })
        await #expect(throws: ExtensionPeerError.self) {
            try await peer.collect(machineID: UUID(), force: true) { output.append($0, error: $1) }
        }
        #expect(output.snapshot.isEmpty)
        #expect(await transport.released == [transport.jobID])
        let timed = UsageMachinesProgressTransport(data: try await nativeDocument(), output: output)
        await timed.setFrames([timed.frame(sequence: 0, next: 0, chunks: [])])
        let limited = UsageMachinesPeer(
            active: { true }, invoke: { try await timed.invoke($0, payload: $1) },
            collectionTimeout: 0.001)
        await #expect(throws: ExtensionPeerError.self) {
            try await limited.collect(machineID: UUID(), force: true) {
                output.append($0, error: $1)
            }
        }
        #expect(await timed.released == [timed.jobID])
        #expect(await timed.resultReads == 0)
    }

    private func nativeDocument() async throws -> Data {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent("projects/fixture")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n url = https://github.com/example/fixture.git\n".utf8)
            .write(to: project.appendingPathComponent(".git/config"))
        let journal = home.appendingPathComponent(".claude/projects/fixture/session.jsonl")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let row = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-10-09T01:00:00Z", "sessionId": "fixture-session",
            "requestId": "fixture-request", "costUSD": 1, "cwd": project.path,
            "message": [
                "id": "fixture-message", "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 10, "output_tokens": 5], "content": "Fixture prompt",
            ],
        ])
        try (row + Data("\n".utf8)).write(to: journal)
        let data = try await UsageNativeCollector.collect(
            home: home, dataDirectory: root.appendingPathComponent("data"),
            environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"], onEvent: { _ in })
        try #require(UsageHistory.isValidDocument(data))
        return data
    }

    private func fixture() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 8, "generatedAt": "2026-10-09T12:00:00Z", "sources": ["codex"],
            "defaultSources": ["codex"], "sourceMeta": ["codex": ["label": "Sample"]],
            "sessions": [], "daily": [],
            "totals": [
                "cost": 0, "tokens": 0, "inputTokens": 0, "outputTokens": 0,
                "cacheCreationTokens": 0, "cacheReadTokens": 0, "bySource": [:],
            ], "padding": String(repeating: "x", count: 300_000),
        ])
    }
}

enum UsageMachinesInvalidProgress: CaseIterable, Sendable {
    case foreignJob, wrongSequence, wrongNext, wrongChunk, badChannel, emptyChunk
    case oversizedChunk, earlyReceipt, missingReceipt, failed, overflow, cancelled
}

private enum UsageMachinesOutputFailure: Error { case rejected }

private final class UsageMachinesProgressOutput: @unchecked Sendable {
    struct Output { let data: Data; let error: Bool }
    private let lock = NSLock()
    private var values: [Output] = []
    var snapshot: [Output] { lock.withLock { values } }
    func append(_ data: Data, error: Bool) {
        lock.withLock { values.append(.init(data: data, error: error)) }
    }
}

private actor UsageMachinesProgressTransport {
    let jobID = UUID()
    let resultID = UUID()
    let data: Data
    let output: UsageMachinesProgressOutput
    var released: [UUID] = []
    var sequences: [UInt64] = []
    var resultReads = 0
    var polling = false
    var active = true
    private var frames: [UsageMachinesPeer.ProgressFrame] = []
    private var suspended = false
    private var withdraw = false
    init(data: Data, output: UsageMachinesProgressOutput) { self.data = data; self.output = output }
    var receipt: UsageMachinesPeer.Receipt {
        .init(
            collectionID: resultID, byteCount: data.count, sha256: UsageMachinesPeer.hash(data),
            generatedAt: ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[
                "generatedAt"] as? String ?? "")
    }
    func frame(
        sequence: UInt64, next: UInt64, chunks: [UsageMachinesPeer.ProgressChunk],
        state: UsageMachinesPeer.ProgressState = .running, receipt: UsageMachinesPeer.Receipt? = nil
    ) -> UsageMachinesPeer.ProgressFrame {
        .init(
            collectionID: jobID, sequence: sequence, nextSequence: next, chunks: chunks,
            state: state, receipt: receipt, error: nil)
    }
    func setFrames(_ frames: [UsageMachinesPeer.ProgressFrame]) { self.frames = frames }
    func suspendPoll() { suspended = true }
    func withdrawAfterReply() { withdraw = true }
    func invoke(_ command: String, payload: Data) async throws -> Data {
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let encoder = JSONEncoder()
        switch command {
        case "machines.usage.start":
            #expect(Set(object.keys) == ["machineID", "force"])
            return try JSONSerialization.data(withJSONObject: ["collectionID": jobID.uuidString])
        case "machines.usage.progress":
            #expect(object["collectionID"] as? String == jobID.uuidString)
            let sequence = try #require(object["sequence"] as? UInt64)
            sequences.append(sequence)
            if sequences.count == 2 { #expect(output.snapshot.count == 1) }
            polling = true
            if suspended { try await Task.sleep(for: .seconds(60)) }
            guard !frames.isEmpty else { throw ExtensionPeerError.invalidRequest }
            if withdraw { active = false }
            return try encoder.encode(frames.removeFirst())
        case "machines.usage.result":
            #expect(object["collectionID"] as? String == resultID.uuidString)
            let offset = try #require(object["offset"] as? Int)
            let end = min(data.count, offset + 262_144)
            resultReads += 1
            return try encoder.encode(
                UsageMachinesPeer.Chunk(
                    offset: offset, data: data.subdata(in: offset..<end),
                    finished: end == data.count))
        case "machines.usage.cancel":
            let text = try #require(object["collectionID"] as? String)
            released.append(try #require(UUID(uuidString: text)))
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
