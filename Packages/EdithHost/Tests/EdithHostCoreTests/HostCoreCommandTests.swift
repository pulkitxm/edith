import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreCommandRuntimeTests {
    @Test func actualQueueExecutesSeparatedBytesAndRetainsResultAndEventsAcrossRestart()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await runtime.startCommands()
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'out\\000tail'; printf 'err\\377' >&2; exit 7"],
            environment: [:], currentDirectoryURL: fixture.directory, timeout: 5,
            maximumOutputBytes: 2 << 20, terminatesProcessGroup: true)
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command, title: "Synthetic owned command",
            payload: try HostAgentPayload.encode(request))
        let snapshot: HostAgentTaskSnapshot = try await call(runtime, .submit, submission)
        let result = try await terminal(runtime, snapshot.id)
        #expect(result.snapshot.state == .failed && result.snapshot.failureCode == "commandExit")
        let command = try HostAgentPayload.decode(
            CLICommandResult.self, from: #require(result.result))
        #expect(command.terminationStatus == 7)
        #expect(command.standardOutputData == Data([111, 117, 116, 0, 116, 97, 105, 108]))
        #expect(command.standardErrorData == Data([101, 114, 114, 255]))
        #expect(
            runtime.snapshot().commandTasks?.contains {
                $0.id == snapshot.id && $0.state == .failed
            } == true)
        await runtime.shutdown()
        let reopened = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await reopened.startCommands()
        let retained: HostAgentTaskStatus = try await call(
            reopened, .status, HostAgentTaskIDRequest(id: snapshot.id))
        #expect(retained == result)
        #expect(
            reopened.snapshot().agent?.events.contains {
                $0.taskID == snapshot.id && $0.name == "task.failed"
            } == true)
        await reopened.shutdown()
    }

    @Test func queueCancellationAndCoreShutdownDrainActualOwnedCommandGroups() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await runtime.startCommands()
        let pidFile = fixture.directory.appendingPathComponent("pid")
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > pid; exec /bin/sleep 120"], environment: [:],
            currentDirectoryURL: fixture.directory, timeout: 120, maximumOutputBytes: 2 << 20,
            terminatesProcessGroup: true)
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command, title: "Synthetic owned sleep",
            payload: try HostAgentPayload.encode(request))
        let snapshot: HostAgentTaskSnapshot = try await call(runtime, .submit, submission)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        #expect(getpgid(pid) == pid && pid != getpid())
        let cancelled: HostAgentTaskSnapshot = try await call(
            runtime, .cancel, HostAgentTaskIDRequest(id: snapshot.id))
        #expect([.cancelling, .cancelled].contains(cancelled.state))
        let finished = try await terminal(runtime, snapshot.id)
        #expect(finished.snapshot.state == .cancelled)
        await runtime.shutdown()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(runtime.snapshot().commandTasks?.allSatisfy { $0.state.isTerminal } == true)
        await #expect(throws: HostAgentCommandError.self) {
            try await runtime.command(.init(operation: .list))
        }
    }

    private func call<T: Decodable>(
        _ runtime: HostCoreRuntime, _ operation: HostAgentCommandOperation,
        _ payload: some Encodable
    ) async throws -> T {
        try HostAgentPayload.decode(
            T.self,
            from: await runtime.command(
                .init(operation: operation, payload: HostAgentPayload.encode(payload))
            ).encoded())
    }
    private func terminal(_ runtime: HostCoreRuntime, _ id: UUID) async throws
        -> HostAgentTaskStatus
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let status: HostAgentTaskStatus = try await call(
                runtime, .status, HostAgentTaskIDRequest(id: id))
            if status.snapshot.state.isTerminal { return status }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostWorkerError.timedOut
    }
    private struct Fixture {
        let directory: URL
        let identity: HostIdentity
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "core-wire-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.wire-" + UUID().uuidString,
                supportDirectory: directory)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

@Suite struct HostCoreFramesTests {
    @Test func originalRetainedResultFitsTheWireWithoutAnotherBase64Layer() throws {
        let status = HostAgentTaskStatus(
            snapshot: .init(
                id: UUID(), operation: "command.run", title: "Synthetic result", state: .succeeded,
                submittedAt: Date(timeIntervalSince1970: 1_000_000)),
            result: Data(repeating: 42, count: 8 << 20))
        let payload = try HostAgentPayload.encode(status)
        let response = HostCoreResponse(
            token: UUID(), commandResult: try JSONDecoder().decode(HostCLIJSON.self, from: payload))
        let frame = try HostCoreFrames.encode(response)
        #expect(frame.count < HostCoreFrames.maximumBytes && frame.count > 8 << 20)
        var decoder = HostCoreFrames()
        let first = try decoder.append(frame.prefix(4096))
        #expect(first.isEmpty)
        let second = try decoder.append(frame.dropFirst(4096))
        let decoded = try JSONDecoder().decode(HostCoreResponse.self, from: #require(second.first))
        let retained = try HostAgentPayload.decode(
            HostAgentTaskStatus.self, from: #require(decoded.commandResult).encoded())
        #expect(retained == status)
        #expect(HostWorkerFrames.maximumBytes == 65_536)
        #expect(throws: HostWorkerError.self) {
            try decoder.append(Data(repeating: 65, count: HostCoreFrames.maximumBytes))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                HostCoreCommandRequest.self,
                from: Data("{\"operation\":\"arbitrary.operation\",\"payload\":{}}".utf8))
        }
    }

    @Test func concurrentLargeFramesRemainWholeAndBrokenPipeDoesNotChangeGlobalSignals()
        async throws
    {
        let pipe = Pipe()
        let writer = try HostCorePipeWriter(descriptor: pipe.fileHandleForWriting.fileDescriptor)
        let values = ["a", "b"].map {
            HostCLIJSON.object([
                "id": .string($0), "bytes": .string(String(repeating: $0, count: 1 << 20)),
            ])
        }
        let reader = Task.detached {
            var frames = HostCoreFrames()
            var received: [Data] = []
            while received.count < 2 {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(
                    pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw HostWorkerError.exited }
                received += try frames.append(Data(bytes.prefix(count)))
            }
            return try received.map { try JSONDecoder().decode(HostCLIJSON.self, from: $0) }
        }
        async let first: Void = writer.send(values[0])
        async let second: Void = writer.send(values[1])
        _ = try await (first, second)
        let received = try await reader.value
        #expect(Set(received.compactMap { $0.object?["id"]?.string }) == ["a", "b"])
        #expect(
            received.allSatisfy { value in
                let id = value.object?["id"]?.string ?? ""
                return value.object?["bytes"]?.string == String(repeating: id, count: 1 << 20)
            })
        await writer.shutdown()
        try pipe.fileHandleForReading.close(); try pipe.fileHandleForWriting.close()
        var before = sigaction()
        #expect(sigaction(SIGPIPE, nil, &before) == 0)
        let broken = Pipe()
        let closedWriter = try HostCorePipeWriter(
            descriptor: broken.fileHandleForWriting.fileDescriptor)
        try broken.fileHandleForReading.close()
        await #expect(throws: HostWorkerError.self) {
            try await closedWriter.send(Data("synthetic\n".utf8))
        }
        await closedWriter.shutdown()
        var after = sigaction()
        #expect(sigaction(SIGPIPE, nil, &after) == 0)
        #expect(before.sa_flags == after.sa_flags && before.sa_mask == after.sa_mask)
        #expect(
            unsafeBitCast(before.__sigaction_u.__sa_handler, to: UInt.self)
                == unsafeBitCast(after.__sigaction_u.__sa_handler, to: UInt.self))
    }
}
