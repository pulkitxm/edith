import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCLIStreamTests {
    @Test func sdkWirePreservesCallerDirectoryAndOrderedChannelsBeforeCompletion() async throws {
        let fixture = CLIStreamFixture()
        let context = try HostCLIInvocationContext(
            arguments: ["run", "synthetic"], standardInput: Data("input".utf8),
            workingDirectory: "/synthetic/caller")
        let stream = try await HostCLIStream.start(
            owner: "studio", operation: "studio.cli.stream", request: context,
            invoke: { try await fixture.invoke($0) })
        let first = try await stream.read()
        #expect(first.state == .running && first.chunks.count == 2 && first.nextSequence == 2)
        #expect(first.chunks[0].channel == .stdout && first.chunks[1].channel == .stderr)
        #expect(await fixture.context()?.workingDirectory == "/synthetic/caller")
        #expect(await fixture.context()?.standardInput == Data("input".utf8))
        let last = try await stream.read()
        #expect(last.state == .completed && last.exitCode == 130 && last.chunks[0].sequence == 2)
        #expect(await fixture.operations().last == "studio.cli.stream.end")
    }

    @Test func staleCursorTriggersCancelAndEndInsteadOfPrintingStaleBytes() async throws {
        let fixture = CLIStreamFixture(stale: true)
        let stream = try await HostCLIStream.start(
            owner: "studio", operation: "studio.cli.stream",
            request: HostCLIInvocationContext(arguments: []),
            invoke: { try await fixture.invoke($0) })
        await #expect(throws: HostCLIError.self) { try await stream.read() }
        #expect(
            await fixture.operations().suffix(2) == [
                "studio.cli.stream.cancel", "studio.cli.stream.end",
            ])
    }

    @Test func contextRejectsRelativeDirectoryAndOversizedStdin() throws {
        #expect(throws: HostCLIError.self) {
            try HostCLIInvocationContext(arguments: [], workingDirectory: "relative")
        }
        #expect(throws: HostCLIError.self) {
            try HostCLIInvocationContext(
                arguments: [],
                standardInput: Data(count: HostCLIInvocationContext.maximumInputBytes + 1))
        }
    }
}

private actor CLIStreamFixture {
    private var start: HostCLIInvocationContext?
    private var handle: HostCLIStreamHandle?
    private var calls: [String] = []
    private let stale: Bool
    init(stale: Bool = false) { self.stale = stale }
    func operations() -> [String] { calls }
    func context() -> HostCLIInvocationContext? { start }
    func invoke(_ request: HostCLIRequest) throws -> Data {
        let operation = request.operation ?? ""
        calls.append(operation)
        let object = try JSONDecoder().decode(HostCLIJSON.self, from: request.payload).object ?? [:]
        if operation.hasSuffix(".start") {
            start = try JSONDecoder().decode(
                HostCLIInvocationContext.self, from: (object["request"] ?? .null).encoded())
            let session = try #require(object["session"]?.string.flatMap(UUID.init(uuidString:)))
            let handle = HostCLIStreamHandle(owner: "studio", session: session, token: UUID())
            self.handle = handle
            return try JSONEncoder().encode(handle)
        }
        if operation.hasSuffix(".read") {
            let handle = try #require(handle)
            let sequence = UInt64(object["sequence"]?.integer ?? 0)
            let chunks =
                sequence == 0
                ? [
                    HostCLIStreamFrame.Chunk(
                        sequence: 0, channel: .stdout, data: Data("first".utf8)),
                    .init(sequence: 1, channel: .stderr, data: Data("progress".utf8)),
                ] : [.init(sequence: 2, channel: .stdout, data: Data("last".utf8))]
            let frame = HostCLIStreamFrame(
                handle: handle, sequence: stale ? 9 : sequence,
                nextSequence: sequence + UInt64(chunks.count), chunks: chunks,
                state: sequence == 0 ? .running : .completed, exitCode: sequence == 0 ? nil : 130)
            return try JSONEncoder().encode(frame)
        }
        return Data("{}".utf8)
    }
}
