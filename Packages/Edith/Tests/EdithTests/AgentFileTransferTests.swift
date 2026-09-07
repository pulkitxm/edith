import Darwin
import Foundation
import Testing

@testable import Edith
@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentFileTransferTests {
    @Test func oneDaemonTaskTransfersAPlanAndPublishesOrderedProgress() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source, with spaces.bin")
        let target = root.appendingPathComponent("target, with spaces.bin")
        let bytes = Data((0..<524_288).map { UInt8($0 % 256) })
        try bytes.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let progress = FileTransferTestProgress()
        let local = RemoteTransferEndpoint.local(machineID: Machine.localID, name: "This Mac")
        let outcome = try await RemoteTransferOperationExecution.execute(
            plan(source, target), from: local, to: local, confirmsReplacement: false,
            taskClient: client
        ) { processed, total in
            await progress.append(processed, total)
        }
        #expect(outcome.completed.count == 1)
        #expect(outcome.failures.isEmpty)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(
            try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
                == 0o640)
        #expect(await progress.values == [[1, 1]])
        #expect(await service.snapshots().map(\.operation) == [AgentFileTransferRequest.operation])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func failedReplacementPreservesTheOriginalAndRetainsThePartialOutcome() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try Data("source".utf8).write(to: source)
        try Data("original".utf8).write(to: target)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let outcome = try await client.transferFiles(
            AgentFileTransferRequest(
                plan: plan(source, target), source: .local, destination: .local,
                confirmsReplacement: false, moving: true))
        #expect(outcome.completed.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(await service.snapshots().first?.state == .failed)
        #expect(await service.snapshots().first?.failureCode == "filesIncomplete")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func aMoveFinishesAfterItsSubmittingClientDisconnects() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try Data("moved".utf8).write(to: source)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let original = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let request = AgentFileTransferRequest(
            plan: plan(source, target), source: .local, destination: .local,
            confirmsReplacement: false, moving: true)
        let receipt = try await original.submit(
            AgentTaskSubmission(
                operation: AgentFileTransferRequest.operation, title: "Move fixture",
                payload: AgentPayload.encode(request)))
        original.client.reset()
        let replacement = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let outcome = try AgentPayload.decode(
            RemoteTransferOutcome.self, from: await replacement.wait(receipt.id))
        #expect(outcome.completed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "moved")
    }

    @Test func movingAFileOntoItselfFailsWithoutRemovingIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("original".utf8).write(to: source)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        await #expect(throws: AgentTaskFailure.self) {
            _ = try await client.transferFiles(
                AgentFileTransferRequest(
                    plan: plan(source, source), source: .local, destination: .local,
                    confirmsReplacement: true, moving: true))
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

    @Test(arguments: [false, true]) func aliasesCannotTurnAMoveIntoDeletingItsDestination(
        hardLink: Bool
    ) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("original".utf8).write(to: source)
        let target: URL
        if hardLink {
            target = root.appendingPathComponent("hard link")
            try FileManager.default.linkItem(at: source, to: target)
        } else {
            let alias = root.appendingPathComponent("directory alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            target = alias.appendingPathComponent("source")
        }
        let request = AgentFileTransferRequest(
            plan: RemoteTransferPlan(
                destination: root.path,
                items: [
                    RemoteTransferPlanItem(
                        sourcePath: source.path, destinationPath: target.path,
                        replacesExisting: true)
                ],
                skipped: []),
            source: .local, destination: .local, confirmsReplacement: true, moving: true)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        await #expect(throws: AgentTaskFailure.self) { _ = try await client.transferFiles(request) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
    }

    @Test func directoryPlansFailExplicitlyWithoutChangingTheirContents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source folder", isDirectory: true)
        let target = root.appendingPathComponent("target folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let contents = source.appendingPathComponent("keep")
        try Data("original".utf8).write(to: contents)
        let service = try AgentTaskService(directory: nil)
        await AgentMachineOperations.register(on: service)
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let outcome = try await client.transferFiles(
            AgentFileTransferRequest(
                plan: plan(source, target), source: .local, destination: .local,
                confirmsReplacement: false, moving: true))
        #expect(outcome.completed.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(try String(contentsOf: contents, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func cancellingLocalCopyTerminatesTheProcessAndRemovesStaging() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("protected target")
        let pidFile = root.appendingPathComponent("copy process")
        try Data("replacement".utf8).write(to: source)
        try Data("original".utf8).write(to: target)
        let local = RemoteTransferEndpoint.local(machineID: Machine.localID, name: "This Mac") {
            _, staged in
            _ = try await CLICommandRunner.runLocalSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "printf '%s\\n' \"$$\" > \"$2\"; printf partial > \"$1\"; exec sleep 30",
                        "copy", staged.path, pidFile.path,
                    ], environment: ["PATH": "/usr/bin:/bin"], timeout: 5,
                    terminatesProcessGroup: true),
                onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        }
        let task = Task { try await local.store(source, at: target.path, replacing: true) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        var staging: [String] = []
        while ContinuousClock.now < deadline {
            staging = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.contains(NameConflicts.stagingSuffix) }
            if !staging.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!staging.isEmpty)
        let pid = try #require(
            Int32(
                String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) != 0)
        try FileManager.default.removeItem(at: pidFile)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "file-transfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func plan(_ source: URL, _ destination: URL) -> RemoteTransferPlan {
        RemoteTransferPlan(
            destination: destination.deletingLastPathComponent().path,
            items: [
                RemoteTransferPlanItem(
                    sourcePath: source.path, destinationPath: destination.path,
                    replacesExisting: false)
            ],
            skipped: [])
    }
}

@Suite @MainActor struct FinderDaemonTransferTests {
    @Test func finderExposesDaemonProgressAndCancelsTheOwnedTransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "finder-daemon-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: source)
        let service = try AgentTaskService(directory: nil)
        await service.register(operation: AgentFileTransferRequest.operation) { _, context in
            context.report("files:1:2")
            try await Task.sleep(for: .seconds(10))
            return Data()
        }
        let listener = TaskTestListener(service: service)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let model = FinderModel(session: session, path: destination.path, transferClient: client)
        let upload = Task { await model.upload([source]) }
        defer { upload.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while model.progress?.completed != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.progress?.total == 2)
        #expect(model.canCancelTransfer)
        model.cancelTransfer()
        await upload.value
        #expect(!model.canCancelTransfer)
        #expect(model.progress == nil)
        #expect(model.errorMessage == nil)
        for _ in 0..<100 {
            if await service.snapshots().first?.state == .cancelled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await service.snapshots().first?.state == .cancelled)
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("source").path))
    }
}

private actor FileTransferTestProgress {
    var values: [[Int]] = []
    func append(_ processed: Int, _ total: Int) { values.append([processed, total]) }
}
