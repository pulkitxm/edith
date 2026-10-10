import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

extension ExtensionCLIExecutionTests {
    @Test func streamsBeforeCompletionPreservingOrderAndBinding() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let handle = try streams.start(StreamCommand.self, request: start("wait"))
        try await waitUntil { StreamCommand.waiting }
        let first = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: 0))
        try first.validate()
        #expect(first.state == .running)
        #expect(first.chunks.map(\.channel) == [.stdout, .stderr, .stdout])
        #expect(
            first.chunks.map { String(decoding: $0.data, as: UTF8.self) } == [
                "first", "diagnostic", "last",
            ])
        #expect(throws: ExtensionPeerError.self) {
            try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: 0))
        }
        for wrong in [
            ExtensionCLIStreamHandle(owner: "other", session: handle.session, token: handle.token),
            ExtensionCLIStreamHandle(owner: handle.owner, session: UUID(), token: handle.token),
            ExtensionCLIStreamHandle(owner: handle.owner, session: handle.session, token: UUID()),
        ] {
            #expect(throws: ExtensionPeerError.self) { try streams.cancel(wrong) }
        }
        try streams.cancel(handle)
        let cancelled = try await terminal(streams, handle: handle, sequence: first.nextSequence)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.exitCode == nil)
        try streams.end(handle)
        #expect(throws: ExtensionPeerError.self) {
            try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: first.nextSequence))
        }
        let reply = try await ExtensionCLIExecution.run(StreamCommand.self, arguments: ["done"])
        #expect(reply.stdout == "firstlast")
        #expect(ExtensionCLIContext.request == nil)
    }

    @Test func boundsBuffersAndDrainsBeforeOverflowResult() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let handle = try streams.start(StreamCommand.self, request: start("overflow"))
        try await waitUntil { StreamCommand.produced }
        var sequence: UInt64 = 0
        var bytes = 0
        var frames = 0
        while true {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: sequence))
            try frame.validate()
            frames += 1
            sequence = frame.nextSequence
            bytes += frame.chunks.reduce(0) { $0 + $1.data.count }
            if frame.state != .running { #expect(frame.state == .overflow); break }
            await Task.yield()
        }
        #expect(bytes <= ExtensionCLIStreams.maximumBufferedBytes)
        #expect(bytes == 1_024 * 1_024)
        #expect(frames >= 4)
        try streams.end(handle)
    }

    @Test func preservesExactExitAndCancelsOnDeadlineIdleAndStop() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let handle = try streams.start(StreamCommand.self, request: start("failure"))
        let result = try await terminal(streams, handle: handle, sequence: 0)
        #expect(result.state == .completed)
        #expect(result.exitCode == 4)
        #expect(
            String(decoding: result.chunks.flatMap { $0.data }, as: UTF8.self).contains(
                "synthetic unavailable"))
        try streams.end(handle)
        let timed = try streams.start(StreamCommand.self, request: start("wait", deadline: 0.02))
        let timeout = try await terminal(streams, handle: timed, sequence: 0)
        #expect(timeout.state == .timedOut)
        try streams.end(timed)
        let stopped = try streams.start(StreamCommand.self, request: start("wait"))
        try await waitUntil { StreamCommand.waiting }
        await streams.stopAndWait()
        #expect(!StreamCommand.waiting)
        #expect(throws: ExtensionPeerError.self) { try streams.cancel(stopped) }
        #expect(throws: ExtensionPeerError.self) {
            try streams.start(StreamCommand.self, request: start("done"))
        }
        let idle = try ExtensionCLIStreams(owner: "synthetic", idleTimeout: .milliseconds(20))
        let idleHandle = try idle.start(StreamCommand.self, request: start("wait"))
        try await waitUntil { StreamCommand.waiting }
        try await waitUntil { !StreamCommand.waiting }
        #expect(throws: ExtensionPeerError.self) {
            try idle.read(ExtensionCLIStreamRead(handle: idleHandle, sequence: 0))
        }
        await idle.stopAndWait()
    }

    @Test func routesFixedInvokeOperationsAndValidatesLimits() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let encoded = try streams.invoke(
            StreamCommand.self, operation: "synthetic.cli.stream.start",
            prefix: "synthetic.cli.stream", payload: JSONEncoder().encode(start("done")))
        let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: encoded)
        let frame = try await terminal(streams, handle: handle, sequence: 0)
        #expect(frame.exitCode == 0)
        let end = try streams.invoke(
            StreamCommand.self, operation: "synthetic.cli.stream.end",
            prefix: "synthetic.cli.stream", payload: JSONEncoder().encode(handle))
        #expect(end == Data("{}".utf8))
        for deadline in [0.0, -1, .infinity, 21_601] {
            #expect(throws: ExtensionPeerError.self) {
                try streams.start(StreamCommand.self, request: start("done", deadline: deadline))
            }
        }
        #expect(throws: ExtensionPeerError.self) {
            try streams.invoke(
                StreamCommand.self, operation: "synthetic.shell", prefix: "synthetic.cli.stream",
                payload: Data("{}".utf8))
        }
    }

    @Test func boundsSessionCapacityAndRetainsCancelledTasksUntilDrain() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let request = try start("wait")
        let first = try streams.start(StreamCommand.self, request: request)
        #expect(throws: ExtensionPeerError.self) {
            try streams.start(StreamCommand.self, request: request)
        }
        var handles = [first]
        for _ in 1..<ExtensionCLIStreams.maximumSessions {
            handles.append(try streams.start(StreamCommand.self, request: start("done")))
        }
        #expect(throws: ExtensionPeerError.self) {
            try streams.start(StreamCommand.self, request: start("done"))
        }
        await streams.stopAndWait()
        let reply = try await ExtensionCLIExecution.run(StreamCommand.self, arguments: ["done"])
        #expect(reply.exitCode == 0)
        #expect(ExtensionCLIContext.request == nil)
    }

    @Test func chunkCountOverflowAndUnicodeBytesStayBounded() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let handle = try streams.start(StreamCommand.self, request: start("tiny-overflow"))
        try await waitUntil { StreamCommand.produced }
        var sequence: UInt64 = 0
        var bytes = Data()
        while true {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: sequence))
            try frame.validate()
            for chunk in frame.chunks { bytes.append(chunk.data) }
            sequence = frame.nextSequence
            if frame.state != .running { #expect(frame.state == .overflow); break }
            await Task.yield()
        }
        #expect(sequence == 4_096)
        #expect(bytes == Data(String(repeating: "é", count: 4_096).utf8))
        try streams.end(handle)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < limit { await Task.yield() }
        guard condition() else {
            throw CLIFailure("synthetic command did not reach expected state")
        }
    }

    private func start(_ value: String, deadline: Double = 30) throws -> ExtensionCLIStreamStart {
        try ExtensionCLIStreamStart(
            owner: "synthetic", session: UUID(),
            request: ExtensionCLIRequest(arguments: [value], workingDirectory: "/tmp/synthetic"),
            deadline: deadline)
    }

    private func terminal(
        _ streams: ExtensionCLIStreams, handle: ExtensionCLIStreamHandle, sequence: UInt64
    ) async throws -> ExtensionCLIStreamFrame {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        var cursor = sequence
        var all: [ExtensionCLIStreamChunk] = []
        while ContinuousClock.now < limit {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: cursor))
            all += frame.chunks
            cursor = frame.nextSequence
            if frame.state != .running {
                return ExtensionCLIStreamFrame(
                    handle: handle, sequence: sequence, nextSequence: cursor, chunks: all,
                    state: frame.state, exitCode: frame.exitCode)
            }
            await Task.yield()
        }
        throw CLIFailure("synthetic stream did not finish")
    }
}

private struct StreamCommand: AsyncParsableCommand {
    @MainActor static var waiting = false
    @MainActor static var produced = false
    @Argument var value: String

    @MainActor mutating func run() async throws {
        Self.produced = false
        if value == "failure" { throw CLIFailure.unavailable("synthetic unavailable") }
        if value == "tiny-overflow" {
            for _ in 0..<4_097 { CLIOut.raw("é") }
            Self.produced = true
            try Task.checkCancellation()
            return
        }
        if value == "overflow" {
            CLIOut.raw(String(repeating: "x", count: 1_024 * 1_024))
            CLIOut.raw("overflow")
            Self.produced = true
            try Task.checkCancellation()
            return
        }
        CLIOut.raw("first")
        CLIOut.rawError("diagnostic")
        CLIOut.raw("last")
        if value == "wait" {
            Self.waiting = true
            defer { Self.waiting = false }
            try await Task.sleep(for: .seconds(30))
        }
    }
}
