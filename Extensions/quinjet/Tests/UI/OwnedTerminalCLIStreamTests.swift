import ArgumentParser
import Darwin
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import QuinjetUI

@MainActor @Suite(.serialized) struct OwnedTerminalCLIStreamTests {
    @Test func actualSharedStreamsPreserveConcurrentPTYBytesInputResizeAndExit() async throws {
        let registry = OwnedTerminalSessionRegistry()
        let streams = try ExtensionCLIStreams(owner: OwnedTerminalSession.owner)
        defer { streams.stop(); registry.stopAll() }
        let first = try start("binary", streams: streams, registry: registry)
        let second = try start("binary", streams: streams, registry: registry)
        for handle in [first, second] {
            let size = try streams.resize(
                .init(handle: handle, sequence: 0, columns: 101, rows: 33))
            #expect(size.accepted && size.nextSequence == 1)
        }
        let firstReady = try await ready(first, streams: streams)
        let secondReady = try await ready(second, streams: streams)
        for handle in [first, second] {
            let bytes = try streams.write(
                .init(handle: handle, sequence: 1, data: Data([0xfe, 0, 0x41])))
            #expect(bytes.accepted && bytes.nextSequence == 2)
        }
        async let a = collect(first, streams: streams, initial: firstReady)
        async let b = collect(second, streams: streams, initial: secondReady)
        let results = try await [a, b]
        let expected =
            Data([0xff, 0, 0x72, 0x65, 0x61, 0x64, 0x79, 0xfe, 0, 0x41]) + Data("33 101\n".utf8)
        for result in results {
            #expect(result.0 == expected)
            #expect(result.1 == .completed && result.2 == 7)
        }
        try streams.end(first); try streams.end(second)
        await streams.stopAndWait()
        await registry.stopAllAndWait()
    }

    @Test func cancellationDrainsOnlyOwnedForegroundProcessAndInputWaiter() async throws {
        let registry = OwnedTerminalSessionRegistry()
        let streams = try ExtensionCLIStreams(owner: OwnedTerminalSession.owner)
        defer { streams.stop(); registry.stopAll() }
        let handle = try start("hold", streams: streams, registry: registry)
        var sequence: UInt64 = 0
        var bytes = Data()
        for _ in 0..<400 {
            let frame = try streams.read(.init(handle: handle, sequence: sequence))
            sequence = frame.nextSequence
            for chunk in frame.chunks { bytes += chunk.data }
            if !bytes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pid = try #require(Int32(String(decoding: bytes, as: UTF8.self)))
        #expect(kill(pid, 0) == 0)
        try streams.cancel(handle)
        try streams.end(handle)
        await streams.stopAndWait()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        await registry.stopAllAndWait()
    }

    @Test func directForegroundInvocationWithoutLiveInputFailsBeforeProcessCreation() async throws {
        let registry = OwnedTerminalSessionRegistry()
        defer { registry.stopAll() }
        await #expect(throws: CLIFailure.self) {
            try await OwnedTerminalContext.$registry.withValue(registry) {
                try await OwnedTerminalCLI.run(
                    .init(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: []))
            }
        }
    }

    private func start(
        _ mode: String, streams: ExtensionCLIStreams, registry: OwnedTerminalSessionRegistry
    ) throws -> ExtensionCLIStreamHandle {
        try OwnedTerminalContext.$registry.withValue(registry) {
            try streams.start(
                SyntheticOwnedTerminalCommand.self,
                request: .init(
                    owner: OwnedTerminalSession.owner, session: UUID(),
                    request: ExtensionCLIRequest(
                        arguments: [mode], workingDirectory: "/tmp", interactive: true),
                    deadline: 30))
        }
    }

    private func ready(_ handle: ExtensionCLIStreamHandle, streams: ExtensionCLIStreams)
        async throws -> (Data, UInt64)
    {
        var sequence: UInt64 = 0
        var output = Data()
        for _ in 0..<1200 {
            let frame = try streams.read(.init(handle: handle, sequence: sequence))
            sequence = frame.nextSequence
            for chunk in frame.chunks { output += chunk.data }
            if output.range(of: Data("ready".utf8)) != nil { return (output, sequence) }
            guard frame.state == .running else { throw ExtensionPeerError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ExtensionPeerError.unavailable
    }

    private func collect(
        _ handle: ExtensionCLIStreamHandle, streams: ExtensionCLIStreams, initial: (Data, UInt64)
    )
        async throws -> (Data, ExtensionCLIStreamFrame.State, Int32?)
    {
        var sequence = initial.1
        var output = initial.0
        for _ in 0..<1200 {
            let frame = try streams.read(.init(handle: handle, sequence: sequence))
            sequence = frame.nextSequence
            for chunk in frame.chunks {
                #expect(chunk.channel == .stdout)
                output += chunk.data
            }
            if frame.state != .running { return (output, frame.state, frame.exitCode) }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ExtensionPeerError.unavailable
    }
}

private struct SyntheticOwnedTerminalCommand: AsyncParsableCommand {
    @Argument var mode: String
    func run() async throws {
        let script =
            mode == "hold"
            ? "printf '%s' $$; exec sleep 30"
            : "stty raw -echo; printf '\\377\\000ready'; dd bs=1 count=3 2>/dev/null; stty size; exit 7"
        let code = try await OwnedTerminalCLI.run(
            .init(
                executable: "/bin/sh", arguments: ["-c", script],
                environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"]))
        if code != 0 { throw ExitCode(code) }
    }
}
