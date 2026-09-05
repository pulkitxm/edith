import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentMachineTaskTests {
    @Test func directSSHEntryPointsUseDaemonTasksBeforeOpeningAConnection() async throws {
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(
            on: service,
            command: { request, _ in
                #expect(request.command == "cat")
                #expect(request.timeout == 3)
                return SSHExecResult(
                    status: 19, stdout: request.standardInput ?? Data(),
                    stderr: Data("diagnostic".utf8))
            })
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let connection = SSHConnection(
            machine: Machine(name: "Direct SSH fixture", host: "fixture.invalid"),
            taskClient: AgentTaskClient(client: listener.client(), pollInterval: 0.01))
        let input = Data([0, 255, 1, 128])
        let result = try await connection.run("cat", stdin: input, timeout: 3)
        #expect(result.stdout == input)
        #expect(result.stderrText == "diagnostic")
        #expect(result.status == 19)
        #expect(await connection.remotePlatform == nil)
        #expect(await service.snapshots().map(\.operation) == [AgentMachineTaskOperation.command])
    }

    @Test(arguments: [AgentMachineTransferDirection.upload, .download])
    func directoryTransferPathsAreRejectedAfterCrossingXPC(
        direction: AgentMachineTransferDirection
    ) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = folder.appendingPathComponent("keep")
        try Data("original".utf8).write(to: contents)
        let calls = MachineTransferTestProgress()
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(
            on: service,
            transfer: { _, _ in
                calls.append(1)
                return 0
            })
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        await #expect(throws: AgentTaskFailure.self) {
            try await client.transferMachineFile(
                AgentMachineTransferRequest(
                    machine: Machine(name: "Directory fixture", host: "fixture.invalid"),
                    direction: direction, localURL: folder, remotePath: "/remote-file"))
        }
        #expect(calls.values.isEmpty)
        #expect(try String(contentsOf: contents, encoding: .utf8) == "original")
    }

    @Test func binaryCommandOutputAndExitStatusCrossXPC() async throws {
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let input = Data([0, 255, 1, 128, 13, 10])
        let result = try await client.runMachineCommand(
            AgentMachineCommandRequest(
                machine: nil, command: "cat; printf warning >&2; exit 23",
                standardInput: input, timeout: 3))
        #expect(result.stdout == input)
        #expect(result.stderrText == "warning")
        #expect(result.status == 23)
        let snapshot = try #require(await service.snapshots().first)
        #expect(snapshot.state == .failed)
        #expect(snapshot.failureCode == "commandExit")
    }

    @Test @MainActor func localSessionCommandsUseTheDaemonWithoutStartingSampling() async throws {
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let session = MachineSession(
            machine: .local, local: true, observesWakeRequests: false, taskClient: client)
        let result = await session.runCommand("cat", stdin: Data("through the daemon".utf8))
        #expect(try result.get() == "through the daemon")
        #expect(!session.isCollecting)
        #expect(session.state == .disconnected)
        #expect(await service.snapshots().map(\.operation) == [AgentMachineTaskOperation.command])
    }

    @Test func machineCommandTimeoutIsRetainedAsFailure() async throws {
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        await #expect(throws: AgentTaskFailure.self) {
            _ = try await client.runMachineCommand(
                AgentMachineCommandRequest(
                    machine: nil, command: "exec sleep 30", timeout: 0.03))
        }
        let snapshot = try #require(await service.snapshots().first)
        #expect(snapshot.state == .failed)
        #expect(snapshot.failureCode == "timedOut")
    }

    @Test func machineFileEntryPointsTransferBytesThroughXPC() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let remote = directory.appendingPathComponent("remote.bin")
        let destination = directory.appendingPathComponent("result.bin")
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        try payload.write(to: source)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(
            on: service,
            transfer: { request, progress in
                let input =
                    request.direction == .upload
                    ? request.localURL : URL(fileURLWithPath: request.remotePath)
                let output =
                    request.direction == .upload
                    ? URL(fileURLWithPath: request.remotePath) : request.localURL
                let data = try Data(contentsOf: input)
                try data.write(to: output)
                progress(Int64(data.count))
                return Int64(data.count)
            })
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let connection = SSHConnection(
            machine: Machine(name: "Transfer fixture", host: "fixture.invalid"), taskClient: client)
        let progress = MachineTransferTestProgress()
        try await connection.upload(localURL: source, toRemotePath: remote.path)
        try await connection.download(remotePath: remote.path, to: destination) {
            progress.append($0)
        }
        #expect(try Data(contentsOf: destination) == payload)
        #expect(progress.values.last == Int64(payload.count))
        #expect(await service.snapshots().count == 2)
        #expect(await connection.remotePlatform == nil)
    }

    @Test func transferSurvivesItsOriginalXPCClientDisconnect() async throws {
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(
            on: service,
            transfer: { _, progress in
                try await Task.sleep(for: .milliseconds(80))
                progress(321)
                return 321
            })
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let original = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let request = AgentMachineTransferRequest(
            machine: Machine(name: "Transfer fixture", host: "fixture.invalid"), direction: .upload,
            localURL: URL(fileURLWithPath: "/tmp/transfer-fixture"), remotePath: "/tmp/destination")
        let submission = AgentTaskSubmission(
            operation: AgentMachineTaskOperation.transfer, title: "Transfer fixture",
            payload: try AgentPayload.encode(request))
        _ = try await original.submit(submission)
        original.client.reset()
        let replacement = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let result = try AgentPayload.decode(
            AgentMachineTransferResult.self, from: await replacement.wait(submission.id))
        #expect(result.bytes == 321)
        #expect(try await replacement.status(submission.id).snapshot.state == .succeeded)
    }

    @Test func remotePublicationRunsAsOneDaemonTask() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        try Data("published".utf8).write(to: source)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(
            on: service,
            transfer: { request, _ in
                #expect(request.direction == .upload)
                #expect(request.replacesExisting == true)
                try FileManager.default.copyItem(
                    at: request.localURL, to: URL(fileURLWithPath: request.remotePath))
                return 9
            })
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let machine = Machine(name: "Publication fixture", host: "fixture.invalid")
        let connection = SSHConnection(
            machine: machine,
            taskClient: AgentTaskClient(client: listener.client(), pollInterval: 0.01))
        try await RemoteTransferEndpoint.remote(machine: machine, connection: connection)
            .store(source, at: destination.path, replacing: true)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "published")
        #expect(await service.snapshots().count == 1)
    }

    @Test func invalidTransferPathFailsBeforeRunningAdapter() async throws {
        let calls = MachineTransferTestProgress()
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(
            on: service,
            transfer: { _, _ in
                calls.append(1)
                return 1
            })
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        await #expect(throws: AgentTaskFailure.self) {
            try await client.transferMachineFile(
                AgentMachineTransferRequest(
                    machine: Machine(name: "Transfer fixture", host: "fixture.invalid"),
                    direction: .download, localURL: URL(string: "https://example.com/file")!,
                    remotePath: "/tmp/file"))
        }
        #expect(calls.values.isEmpty)
    }

    @Test func failedDownloadPreservesExistingFileAndRemovesStagingFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.bin")
        try Data("original".utf8).write(to: destination)
        await #expect(throws: CancellationError.self) {
            try await AgentMachineDownload.write(to: destination) { staged in
                try Data("partial".utf8).write(to: staged)
                throw CancellationError()
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.bin"])
    }

    @Test func successfulDownloadReplacesExistingFileAfterCompletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.bin")
        try Data("original".utf8).write(to: destination)
        try await AgentMachineDownload.write(to: destination) { staged in
            #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
            try Data("complete".utf8).write(to: staged)
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "complete")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["existing.bin"])
    }

    @Test func concurrentCommandsShareConnectionPreparation() async throws {
        let preparations = MachineTransferTestProgress()
        let pool = AgentMachineConnectionPool { _ in
            preparations.append(1)
            try await Task.sleep(for: .milliseconds(30))
        }
        let machine = Machine(name: "Connection fixture", host: "fixture.invalid")
        async let first = pool.connection(for: machine)
        async let second = pool.connection(for: machine)
        let (lhs, rhs) = try await (first, second)
        #expect(lhs === rhs)
        #expect(preparations.values.count == 1)
        let next = try await pool.connection(for: machine)
        #expect(next === lhs)
        #expect(preparations.values.count == 2)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("machine-task-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class MachineTransferTestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var valuesStorage: [Int64] = []
    var values: [Int64] { lock.withLock { valuesStorage } }
    func append(_ value: Int64) { lock.withLock { valuesStorage.append(value) } }
}
