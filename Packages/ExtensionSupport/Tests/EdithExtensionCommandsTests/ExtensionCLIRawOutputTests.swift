import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

extension ExtensionCLIExecutionTests {
    @Test func binaryStreamsPreserveInvalidUTF8NULBoundariesAndChannelOrder() async throws {
        let streams = try ExtensionCLIStreams(owner: "raw-fixture")
        let handle = try streams.start(
            BinaryCommand.self,
            request: ExtensionCLIStreamStart(
                owner: streams.owner, session: UUID(),
                request: ExtensionCLIRequest(arguments: ["mixed"])))
        var cursor: UInt64 = 0
        var chunks: [ExtensionCLIStreamChunk] = []
        var frames = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            guard ContinuousClock.now < deadline else { throw CLIFailure("Stream timed out") }
            let frame = try streams.read(.init(handle: handle, sequence: cursor))
            let encoded = try JSONEncoder().encode(frame)
            let decoded = try JSONDecoder().decode(ExtensionCLIStreamFrame.self, from: encoded)
            try decoded.validate()
            #expect(decoded.chunks == frame.chunks)
            #expect(frame.chunks.reduce(0) { $0 + $1.data.count } <= 256 * 1_024)
            #expect(frame.chunks.allSatisfy { $0.data.count <= 64 * 1_024 })
            if !frame.chunks.isEmpty { frames += 1 }
            chunks += frame.chunks
            cursor = frame.nextSequence
            if frame.state != .running {
                #expect(frame.state == .completed && frame.exitCode == 0)
                break
            }
            await Task.yield()
        }
        #expect(frames >= 2)
        #expect(chunks.map(\.sequence) == Array(0..<UInt64(chunks.count)))
        #expect(
            chunks.map(\.channel) == [
                .stdout, .stdout, .stdout, .stderr, .stderr, .stderr, .stdout, .stderr,
            ])
        var stdout = Data()
        var stderr = Data()
        for chunk in chunks {
            if chunk.channel == .stdout {
                stdout.append(chunk.data)
            } else {
                stderr.append(chunk.data)
            }
        }
        #expect(stdout == BinaryCommand.stdout + Data("text-output".utf8))
        #expect(stderr == BinaryCommand.stderr + Data("text-error".utf8))
        #expect(String(data: stdout, encoding: .utf8) == nil)
        try streams.end(handle)
        await streams.stopAndWait()
    }

    @Test func finiteReplyStrictlyRejectsBinaryAndAcceptsSplitUTF8AndNUL() async throws {
        await #expect(throws: ExtensionPeerError.self) {
            try await ExtensionCLIExecution.run(BinaryCommand.self, arguments: ["invalid"])
        }
        let reply = try await ExtensionCLIExecution.run(BinaryCommand.self, arguments: ["split"])
        #expect(Data(reply.stdout.utf8) == Data([0, 0xF0, 0x9F, 0x98, 0x80, 0]))
        #expect(Data(reply.stderr.utf8) == Data([0, 0xC3, 0xA9]))
        #expect(reply.exitCode == 0)
        #expect(ExtensionCLIContext.rawOutputSink == nil)
        #expect(ExtensionCLIContext.outputSink == nil)
        #expect(ExtensionCLIContext.request == nil)
    }

    @Test func textSinkRetainsParserMessagesAndExplicitlyRejectsRawBytes() async throws {
        let captured = RawCapture()
        let code = try await ExtensionCLIExecution.run(
            BinaryCommand.self, request: .init(arguments: ["invalid"]),
            sink: { captured.append(Data($0.utf8), error: $1) })
        #expect(code == 4)
        #expect(captured.stdout.isEmpty)
        #expect(
            String(data: captured.stderr, encoding: .utf8)?.contains("requires a data sink") == true
        )
        let help = try await ExtensionCLIExecution.run(
            BinaryCommand.self, request: .init(arguments: ["--help"]),
            sink: { captured.append(Data($0.utf8), error: $1) })
        #expect(help == 0)
        #expect(String(data: captured.stdout, encoding: .utf8)?.contains("USAGE:") == true)
    }

    @Test func rawSinkOverridesInheritedOutputForEveryTextAndBinaryWrite() async throws {
        let outer = RawCapture()
        let inner = RawCapture()
        try await ExtensionCLIContext.$rawOutputSink.withValue({ data, error in
            outer.append(data, error: error)
        }) {
            let code = try await ExtensionCLIExecution.run(
                BinaryCommand.self, request: .init(arguments: ["mixed"]),
                rawSink: { data, error in inner.append(data, error: error) })
            #expect(code == 0)
            #expect(inner.stdout == BinaryCommand.stdout + Data("text-output".utf8))
            #expect(inner.stderr == BinaryCommand.stderr + Data("text-error".utf8))
            #expect(outer.stdout.isEmpty && outer.stderr.isEmpty)
            CLIOut.out("outer")
            try CLIOut.raw(Data([0xFF]), error: true)
        }
        #expect(outer.stdout == Data("outer\n".utf8))
        #expect(outer.stderr == Data([0xFF]))
        #expect(ExtensionCLIContext.rawOutputSink == nil)
    }

    @Test func rawFiniteAndStreamOverflowRetainExactAcceptedBytesAndCancel() async throws {
        let accepted = Data(repeating: 0xFF, count: ExtensionCLIStreams.maximumBufferedBytes)
        let streams = try ExtensionCLIStreams(owner: "raw-fixture")
        let handle = try streams.start(
            BinaryCommand.self,
            request: .init(
                owner: streams.owner, session: UUID(), request: .init(arguments: ["overflow"])))
        var cursor: UInt64 = 0
        var output = Data()
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            guard ContinuousClock.now < deadline else {
                throw CLIFailure("Overflow did not cancel")
            }
            let frame = try streams.read(.init(handle: handle, sequence: cursor))
            try frame.validate()
            output.append(contentsOf: frame.chunks.flatMap(\.data))
            cursor = frame.nextSequence
            if frame.state != .running {
                #expect(frame.state == .overflow && frame.exitCode == nil)
                break
            }
            await Task.yield()
        }
        #expect(output == accepted)
        #expect(cursor == 16)
        await streams.stopAndWait()
        await #expect(throws: ExtensionPeerError.self) {
            try await ExtensionCLIExecution.run(BinaryCommand.self, arguments: ["finite-overflow"])
        }
        #expect(
            try await ExtensionCLIExecution.run(BinaryCommand.self, arguments: ["split"]).exitCode
                == 0)
    }
}

private final class RawCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var diagnostic = Data()
    var stdout: Data { lock.withLock { output } }
    var stderr: Data { lock.withLock { diagnostic } }
    func append(_ data: Data, error: Bool) {
        lock.withLock {
            if error { diagnostic.append(data) } else { output.append(data) }
        }
    }
}

private struct BinaryCommand: AsyncParsableCommand {
    static let stdout = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
    static let stderr = Data((0..<150_000).map { UInt8(truncatingIfNeeded: 255 - $0) })
    @Argument var mode: String
    @MainActor mutating func run() async throws {
        switch mode {
        case "mixed":
            try CLIOut.raw(Self.stdout)
            try CLIOut.raw(Self.stderr, error: true)
            CLIOut.raw("text-output")
            CLIOut.rawError("text-error")
        case "invalid":
            try CLIOut.raw(Data([0, 0xFF, 0xC0, 0xAF]), error: true)
        case "split":
            try CLIOut.raw(Data([0, 0xF0, 0x9F]))
            try CLIOut.raw(Data([0x98, 0x80, 0]))
            try CLIOut.raw(Data([0, 0xC3]), error: true)
            try CLIOut.raw(Data([0xA9]), error: true)
        case "overflow":
            try CLIOut.raw(Data(repeating: 0xFF, count: ExtensionCLIStreams.maximumBufferedBytes))
            try CLIOut.raw(Data([0]), error: true)
            try await Task.sleep(for: .seconds(30))
        case "finite-overflow":
            try CLIOut.raw(Data(repeating: 0, count: ExtensionCLIReply.maximumOutputBytes + 1))
        default: throw CLIFailure.usage("Unknown synthetic command")
        }
    }
}
