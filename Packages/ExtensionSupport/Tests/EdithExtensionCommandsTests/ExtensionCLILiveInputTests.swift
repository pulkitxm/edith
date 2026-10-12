import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

extension ExtensionCLIExecutionTests {
    @Test func nestedFiniteExecutionShadowsAndRestoresLiveInputAndCallerMetadata()
        async throws
    {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let initial = Data("{\"jsonrpc\":\"2.0\",".utf8)
        let handle = try streams.start(
            LiveInputCommand.self,
            request: liveStart("nested-input", input: initial, mode: "nested"))
        try await inputWait { LiveInputCommand.started.contains("nested-input") }
        let trailing = Data("\"id\":1}\n{\"id\":2}\n".utf8)
        #expect(
            try streams.write(
                ExtensionCLIStreamWrite(handle: handle, sequence: 0, data: trailing, end: true)
            ).accepted)
        let result = try await inputResult(streams, handle)
        #expect(result.state == .completed && result.code == 0)
        #expect(result.stdout == initial + trailing)
        #expect(result.stderr == Data("finite:/tmp/nested-finite:isolated".utf8))
        #expect(ExtensionCLIContext.input == nil)
        #expect(ExtensionCLIContext.request == nil)
        await streams.stopAndWait()
    }

    @Test func liveInputRoundtripsExactBinaryAndResizeWithIndependentCallerContexts() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let firstBytes = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0) })
        let secondBytes = Data([0, 255, 128, 10])
        let first = try streams.start(
            LiveInputCommand.self, request: liveStart("binary-first", input: firstBytes))
        let second = try streams.start(
            LiveInputCommand.self, request: liveStart("binary-second", input: secondBytes))
        try await inputWait {
            LiveInputCommand.started.contains("binary-first")
                && LiveInputCommand.started.contains("binary-second")
        }
        #expect(LiveInputCommand.contexts["binary-first"]?.standardInput == firstBytes)
        #expect(LiveInputCommand.contexts["binary-second"]?.standardInput == secondBytes)
        #expect(LiveInputCommand.contexts["binary-first"]?.workingDirectory == "/tmp/binary-first")
        #expect(
            LiveInputCommand.contexts["binary-second"]?.workingDirectory == "/tmp/binary-second")
        #expect(LiveInputCommand.contexts["binary-first"]?.interactive == true)
        var expected = firstBytes
        var cursor: UInt64 = 0
        for index in 0..<6 {
            let bytes = Data(repeating: UInt8(128 + index), count: 16_384)
            let ack = try streams.write(
                ExtensionCLIStreamWrite(handle: first, sequence: cursor, data: bytes))
            try ack.validate()
            #expect(ack.accepted)
            cursor = ack.nextSequence
            expected.append(bytes)
        }
        let resize = try streams.resize(
            ExtensionCLIStreamResize(handle: first, sequence: cursor, columns: 1_000, rows: 1))
        cursor = resize.nextSequence
        #expect(resize.accepted)
        #expect(
            try streams.write(
                ExtensionCLIStreamWrite(handle: first, sequence: cursor, data: Data(), end: true)
            ).accepted)
        #expect(
            try streams.write(
                ExtensionCLIStreamWrite(
                    handle: second, sequence: 0, data: Data([192, 0]), end: true)
            ).accepted)
        let firstResult = try await inputResult(streams, first)
        let secondResult = try await inputResult(streams, second)
        #expect(firstResult.state == .completed && firstResult.code == 0)
        #expect(firstResult.stdout == expected)
        #expect(firstResult.stderr == Data("resize:1000x1".utf8))
        #expect(secondResult.stdout == secondBytes + Data([192, 0]))
        #expect(secondResult.stderr.isEmpty)
        #expect(throws: ExtensionPeerError.self) {
            try streams.write(
                ExtensionCLIStreamWrite(handle: first, sequence: cursor + 1, data: Data([1])))
        }
        try streams.end(first)
        try streams.end(second)
        #expect(ExtensionCLIContext.input == nil)
        #expect(ExtensionCLIContext.request == nil)
        await streams.stopAndWait()
    }

    @Test func fixedInputOperationsValidateBindingCursorPayloadAndDecodedDimensions() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let handle = try streams.start(LiveInputCommand.self, request: liveStart("wire"))
        let prefix = "synthetic.cli.stream"
        let bytes = Data(repeating: 255, count: 16_384)
        let payload = try JSONEncoder().encode(
            ExtensionCLIStreamWrite(handle: handle, sequence: 0, data: bytes))
        #expect(payload.count > 32 * 1_024)
        #expect(payload.count < ExtensionCLIStreams.maximumInputPayloadBytes)
        let encoded = try streams.invoke(
            LiveInputCommand.self, operation: prefix + ".write", prefix: prefix, payload: payload)
        let ack = try JSONDecoder().decode(ExtensionCLIStreamInputAck.self, from: encoded)
        try ack.validate()
        #expect(ack.handle == handle && ack.accepted && ack.nextSequence == 1)
        #expect(throws: ExtensionPeerError.self) {
            try streams.invoke(
                LiveInputCommand.self, operation: prefix + ".write", prefix: prefix,
                payload: payload)
        }
        for wrong in [
            ExtensionCLIStreamHandle(owner: "other", session: handle.session, token: handle.token),
            ExtensionCLIStreamHandle(owner: handle.owner, session: UUID(), token: handle.token),
            ExtensionCLIStreamHandle(owner: handle.owner, session: handle.session, token: UUID()),
        ] {
            #expect(throws: ExtensionPeerError.self) {
                try streams.write(ExtensionCLIStreamWrite(handle: wrong, sequence: 1, data: bytes))
            }
            #expect(throws: ExtensionPeerError.self) {
                try streams.resize(
                    ExtensionCLIStreamResize(handle: wrong, sequence: 1, columns: 80, rows: 24))
            }
        }
        for malformed in [
            Data("{}".utf8),
            Data(repeating: 32, count: ExtensionCLIStreams.maximumInputPayloadBytes + 1),
        ] {
            #expect(throws: (any Error).self) {
                try streams.invoke(
                    LiveInputCommand.self, operation: prefix + ".write", prefix: prefix,
                    payload: malformed)
            }
        }
        let bad = try JSONEncoder().encode(
            ExtensionCLIStreamResize(handle: handle, sequence: 1, columns: 1_001, rows: 24))
        #expect(throws: ExtensionPeerError.self) {
            try streams.invoke(
                LiveInputCommand.self, operation: prefix + ".resize", prefix: prefix, payload: bad)
        }
        let valid = try JSONEncoder().encode(
            ExtensionCLIStreamResize(handle: handle, sequence: 1, columns: 80, rows: 24))
        let resize = try JSONDecoder().decode(
            ExtensionCLIStreamInputAck.self,
            from: streams.invoke(
                LiveInputCommand.self, operation: prefix + ".resize", prefix: prefix, payload: valid
            ))
        #expect(resize.accepted && resize.nextSequence == 2)
        #expect(throws: ExtensionPeerError.self) {
            try streams.write(
                ExtensionCLIStreamWrite(handle: handle, sequence: 2, data: bytes + Data([0])))
        }
        #expect(
            try streams.write(
                ExtensionCLIStreamWrite(handle: handle, sequence: 2, data: Data(), end: true)
            ).accepted)
        let result = try await inputResult(streams, handle)
        #expect(result.stdout == bytes)
        #expect(result.stderr == Data("resize:80x24".utf8))
        try streams.end(handle)
        #expect(throws: ExtensionPeerError.self) {
            try streams.write(ExtensionCLIStreamWrite(handle: handle, sequence: 3, data: Data([0])))
        }
    }

    @Test func cancelledBlockedInputDoesNotCancelOtherSessionOrLeakIntoFiniteExecution()
        async throws
    {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let cancelled = try streams.start(LiveInputCommand.self, request: liveStart("cancel-input"))
        let survivor = try streams.start(
            LiveInputCommand.self, request: liveStart("surviving-input"))
        try await inputWait {
            LiveInputCommand.started.contains("cancel-input")
                && LiveInputCommand.started.contains("surviving-input")
        }
        try streams.cancel(cancelled)
        let result = try await inputResult(streams, cancelled)
        #expect(result.state == .cancelled)
        #expect(LiveInputCommand.finished.contains("cancel-input"))
        #expect(!LiveInputCommand.finished.contains("surviving-input"))
        #expect(throws: ExtensionPeerError.self) {
            try streams.resize(
                ExtensionCLIStreamResize(handle: cancelled, sequence: 0, columns: 80, rows: 24))
        }
        let finite = try await ExtensionCLIExecution.run(
            FiniteInputCommand.self,
            request: ExtensionCLIRequest(
                arguments: [], standardInput: Data("finite".utf8), workingDirectory: "/tmp/finite"))
        #expect(finite.stdout == "finite:/tmp/finite:isolated")
        #expect(ExtensionCLIContext.input == nil)
        #expect(
            try streams.write(
                ExtensionCLIStreamWrite(
                    handle: survivor, sequence: 0, data: Data([0, 255]), end: true)
            ).accepted)
        #expect(try await inputResult(streams, survivor).stdout == Data([0, 255]))
        await streams.stopAndWait()
    }

    @Test func stopAndWaitCancelsEightBlockedInputsAndAwaitsOwnedCleanupTasks() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        var handles: [ExtensionCLIStreamHandle] = []
        for index in 0..<8 {
            handles.append(
                try streams.start(
                    LiveInputCommand.self, request: liveStart("drain-\(index)", mode: "drain")))
        }
        try await inputWait {
            (0..<8).allSatisfy { LiveInputCommand.started.contains("drain-\($0)") }
        }
        #expect(throws: ExtensionPeerError.self) {
            try streams.start(LiveInputCommand.self, request: liveStart("ninth"))
        }
        let drain = Task {
            await streams.stopAndWait(); LiveInputCommand.stopReturned = true
        }
        try await inputWait {
            (0..<8).allSatisfy { LiveInputCommand.draining.contains("drain-\($0)") }
        }
        #expect(!LiveInputCommand.stopReturned)
        for index in 0..<8 {
            #expect(!LiveInputCommand.finished.contains("drain-\(index)"))
            #expect(throws: ExtensionPeerError.self) {
                try streams.write(
                    ExtensionCLIStreamWrite(handle: handles[index], sequence: 0, data: Data([0])))
            }
            LiveInputCommand.release.insert("drain-\(index)")
        }
        await drain.value
        #expect(LiveInputCommand.stopReturned)
        #expect(
            (0..<8).allSatisfy {
                LiveInputCommand.finished.contains("drain-\($0)")
                    && LiveInputCommand.cleaned.contains("drain-\($0)")
            })
        #expect(ExtensionCLIContext.input == nil)
        #expect(ExtensionCLIContext.rawOutputSink == nil)
        #expect(
            try await ExtensionCLIExecution.run(FiniteInputCommand.self, arguments: []).exitCode
                == 0)
    }

    @Test func deadlineAndOutputOverflowUnblockLiveInput() async throws {
        let streams = try ExtensionCLIStreams(owner: "synthetic")
        let timed = try streams.start(
            LiveInputCommand.self, request: liveStart("timed-input", deadline: 0.02))
        #expect(try await inputResult(streams, timed).state == .timedOut)
        #expect(LiveInputCommand.finished.contains("timed-input"))
        let overflow = try streams.start(
            LiveInputCommand.self, request: liveStart("overflow-input", mode: "overflow"))
        #expect(try await inputResult(streams, overflow).state == .overflow)
        #expect(LiveInputCommand.finished.contains("overflow-input"))
        #expect(throws: ExtensionPeerError.self) {
            try streams.write(
                ExtensionCLIStreamWrite(handle: overflow, sequence: 0, data: Data([1])))
        }
        await streams.stopAndWait()
    }

    private func liveStart(
        _ id: String, input: Data = Data(), mode: String = "echo", deadline: Double = 30
    ) throws -> ExtensionCLIStreamStart {
        try ExtensionCLIStreamStart(
            owner: "synthetic", session: UUID(),
            request: ExtensionCLIRequest(
                arguments: [id, mode], standardInput: input, workingDirectory: "/tmp/" + id,
                interactive: true), deadline: deadline)
    }

    private func inputWait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        guard condition() else { throw CLIFailure("The synthetic input command did not progress.") }
    }

    private func inputResult(_ streams: ExtensionCLIStreams, _ handle: ExtensionCLIStreamHandle)
        async throws -> (
            stdout: Data, stderr: Data, state: ExtensionCLIStreamFrame.State, code: Int32?
        )
    {
        var stdout = Data()
        var stderr = Data()
        var cursor: UInt64 = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let frame = try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: cursor))
            try frame.validate()
            for chunk in frame.chunks {
                if chunk.channel == .stdout {
                    stdout.append(chunk.data)
                } else {
                    stderr.append(chunk.data)
                }
            }
            cursor = frame.nextSequence
            if frame.state != .running { return (stdout, stderr, frame.state, frame.exitCode) }
            await Task.yield()
        }
        throw CLIFailure("The synthetic input command did not complete.")
    }
}

private struct FiniteInputCommand: AsyncParsableCommand {
    @MainActor mutating func run() async throws {
        let request = ExtensionCLIContext.request
        CLIOut.raw(
            String(decoding: request?.standardInput ?? Data(), as: UTF8.self) + ":"
                + (request?.workingDirectory ?? "") + ":"
                + (ExtensionCLIContext.input == nil ? "isolated" : "leaked"))
    }
}

private struct LiveInputCommand: AsyncParsableCommand {
    @Argument var id: String
    @Argument var mode: String
    @MainActor static var started: Set<String> = []
    @MainActor static var finished: Set<String> = []
    @MainActor static var draining: Set<String> = []
    @MainActor static var cleaned: Set<String> = []
    @MainActor static var release: Set<String> = []
    @MainActor static var contexts: [String: ExtensionCLIRequest] = [:]
    @MainActor static var stopReturned = false

    @MainActor mutating func run() async throws {
        guard let input = ExtensionCLIContext.input, let request = ExtensionCLIContext.request
        else { throw CLIFailure("Missing stream context") }
        Self.started.insert(id)
        Self.contexts[id] = request
        defer { Self.finished.insert(id) }
        let owned =
            mode == "drain"
            ? Task { @MainActor [id] in
                while !Self.release.contains(id) { await Task.yield() }
                #expect(ExtensionCLIContext.input === input)
                #expect(ExtensionCLIContext.request?.workingDirectory == request.workingDirectory)
                Self.cleaned.insert(id)
            } : nil
        do {
            if mode == "nested" {
                let finite = try await ExtensionCLIExecution.run(
                    FiniteInputCommand.self,
                    request: ExtensionCLIRequest(
                        arguments: [], standardInput: Data("finite".utf8),
                        workingDirectory: "/tmp/nested-finite"))
                guard ExtensionCLIContext.input === input,
                    ExtensionCLIContext.request?.workingDirectory == request.workingDirectory,
                    ExtensionCLIContext.request?.standardInput == request.standardInput,
                    ExtensionCLIContext.request?.interactive == true
                else { throw CLIFailure("The nested command leaked its context.") }
                try CLIOut.raw(Data(finite.stdout.utf8), error: true)
            }
            if mode == "overflow" {
                try CLIOut.raw(Data(count: ExtensionCLIStreams.maximumBufferedBytes + 1))
            }
            while let event = try await input.read() {
                switch event {
                case .bytes(let data): try CLIOut.raw(data)
                case .resize(let columns, let rows):
                    try CLIOut.raw(Data("resize:\(columns)x\(rows)".utf8), error: true)
                }
            }
        } catch {
            if let owned {
                Self.draining.insert(id)
                owned.cancel()
                await owned.value
            }
            throw error
        }
        if let owned { owned.cancel(); await owned.value }
    }
}
