import ArgumentParser
import CryptoKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

private enum MachinePTYFixtureContext {
    @TaskLocal static var run: (@MainActor @Sendable () async throws -> Int32)?
}

private struct MachinePTYFixtureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "synthetic-pty")
    func run() async throws {
        guard let run = MachinePTYFixtureContext.run else { throw ExtensionPeerError.unavailable }
        throw ExitCode(try await run())
    }
}

@Suite(.serialized) @MainActor struct MachineCLILiveInputTests {
    private func launch(_ command: String) -> MachinePTYLaunch {
        MachinePTYLaunch(
            executable: "/bin/sh", arguments: ["-c", command],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
            currentDirectory: "/private/tmp", startupCommand: nil)
    }

    private func start(
        _ streams: ExtensionCLIStreams, engine: MachineTerminalEngine,
        machine: Machine, input: Data = Data()
    ) throws -> ExtensionCLIStreamHandle {
        let session = UUID()
        return try MachinePTYFixtureContext.$run.withValue({
            try await engine.runCLI(machine: machine, arguments: [], environment: [])
        }) {
            try MachineWorkingDirectory.$terminalSession.withValue(session.uuidString) {
                try streams.start(
                    MachinePTYFixtureCommand.self,
                    request: ExtensionCLIStreamStart(
                        owner: "machines", session: session,
                        request: try ExtensionCLIRequest(
                            arguments: [], standardInput: input,
                            workingDirectory: "/private/tmp", interactive: true), deadline: 10))
            }
        }
    }

    private func invoke<T: Encodable>(_ streams: ExtensionCLIStreams, _ suffix: String, _ value: T)
        throws -> ExtensionCLIStreamInputAck
    {
        let response = try streams.invoke(
            MachinePTYFixtureCommand.self,
            operation: "machines.cli.stream." + suffix, prefix: "machines.cli.stream",
            payload: JSONEncoder().encode(value))
        return try JSONDecoder().decode(ExtensionCLIStreamInputAck.self, from: response)
    }

    @Test func actualSharedInputDeliversInitialBytesOnceLiveBinaryResizeAndRawOutput() async throws
    {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let initial = Data("synthetic-initial|".utf8)
        let live = Data((0..<32_768).map { UInt8($0 % 251) })
        let count = initial.count + live.count
        let engine = MachineTerminalEngine(
            session: { _ in session },
            interactiveLaunch: { _, _, _ in
                launch(
                    "stty raw -echo; printf ready; dd bs=1 count=\(count) 2>/dev/null | shasum -a 256; stty size; printf '\\377\\000\\342'; sleep 0.03; printf '\\202\\254'; exit 7"
                )
            })
        let streams = try ExtensionCLIStreams(owner: "machines")
        let handle = try start(streams, engine: engine, machine: session.machine, input: initial)
        var cursor: UInt64 = 0
        var output = Data()
        for _ in 0..<500 {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: cursor))
            cursor = frame.nextSequence
            for chunk in frame.chunks { output.append(chunk.data) }
            if String(decoding: output, as: UTF8.self).contains("ready") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(String(decoding: output, as: UTF8.self).contains("ready"))
        let resize = try invoke(
            streams, "resize",
            ExtensionCLIStreamResize(handle: handle, sequence: 0, columns: 104, rows: 35))
        #expect(resize.accepted && resize.nextSequence == 1)
        var sequence: UInt64 = 1
        for offset in stride(from: 0, to: live.count, by: 16_384) {
            let ack = try invoke(
                streams, "write",
                ExtensionCLIStreamWrite(
                    handle: handle, sequence: sequence,
                    data: live.subdata(in: offset..<min(live.count, offset + 16_384))))
            #expect(ack.accepted)
            sequence = ack.nextSequence
        }
        var code: Int32?
        for _ in 0..<500 {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: cursor))
            cursor = frame.nextSequence
            for chunk in frame.chunks {
                #expect(chunk.channel == .stdout); output.append(chunk.data)
            }
            code = frame.exitCode
            if code != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let digest = SHA256.hash(data: initial + live).map { String(format: "%02x", $0) }.joined()
        #expect(code == 7)
        #expect(String(decoding: output, as: UTF8.self).contains(digest))
        #expect(String(decoding: output, as: UTF8.self).contains("35 104"))
        #expect(output.suffix(5) == Data([255, 0, 226, 130, 172]))
        try streams.end(handle)
        await streams.stopAndWait()
        await engine.shutdown()
    }

    @Test func sharedCancellationUnblocksInputReaderDrainsOwnedPTYAndRejectsLateWrites()
        async throws
    {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let engine = MachineTerminalEngine(
            session: { _ in session },
            interactiveLaunch: { _, _, _ in
                launch("stty raw -echo; printf ready; exec cat")
            })
        let streams = try ExtensionCLIStreams(owner: "machines")
        let handle = try start(streams, engine: engine, machine: session.machine)
        var cursor: UInt64 = 0
        var output = Data()
        for _ in 0..<500 {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: cursor))
            cursor = frame.nextSequence
            for chunk in frame.chunks { output.append(chunk.data) }
            if String(decoding: output, as: UTF8.self).contains("ready") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(String(decoding: output, as: UTF8.self).contains("ready"))
        try streams.cancel(handle)
        await streams.stopAndWait()
        #expect(throws: ExtensionPeerError.self) {
            try invoke(
                streams, "write",
                ExtensionCLIStreamWrite(handle: handle, sequence: 0, data: Data([0])))
        }
        await #expect(throws: MachineUIError.self) {
            try await engine.cliInvoke(
                "machines.cli.pty.input",
                payload: JSONEncoder().encode(Input(session: handle.session, bytes: Data([0]))))
        }
        await engine.shutdown()
    }
    private struct Input: Encodable { let session: UUID; let bytes: Data }
}
