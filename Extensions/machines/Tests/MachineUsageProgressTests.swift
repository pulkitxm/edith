@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite @MainActor struct MachineUsageProgressTests {
    private struct Started: Decodable { let collectionID: UUID }
    private let document = Data(
        "{\"schemaVersion\":8,\"generatedAt\":\"2026-10-10T00:00:00Z\",\"sources\":[],\"daily\":[],\"sessions\":[],\"totals\":{}}"
            .utf8)

    private func fixture() -> (URL, MachineRegistry.Files, Machine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = MachineRegistry.Files(machines: root.appendingPathComponent("machines.json"))
        let machine = Machine(name: "synthetic", host: "synthetic.invalid")
        MachineRegistry.add(machine, files)
        return (root, files, machine)
    }

    private func start(_ service: MachineUsageCollectionService, machine: Machine) async throws
        -> UUID
    {
        let payload = try JSONSerialization.data(withJSONObject: [
            "machineID": machine.id.uuidString, "force": true,
        ])
        return try JSONDecoder().decode(
            Started.self, from: await service.execute("machines.usage.start", payload: payload)
        ).collectionID
    }

    private func read(_ service: MachineUsageCollectionService, id: UUID, sequence: UInt64 = 0)
        async throws -> MachineUsageProgress.Frame
    {
        let payload = try JSONSerialization.data(withJSONObject: [
            "collectionID": id.uuidString, "sequence": sequence,
        ])
        return try JSONDecoder().decode(
            MachineUsageProgress.Frame.self,
            from: await service.execute("machines.usage.progress", payload: payload))
    }

    private func cancel(_ service: MachineUsageCollectionService, id: UUID) async throws {
        _ = try await service.execute(
            "machines.usage.cancel", payload: JSONEncoder().encode(StartedPayload(collectionID: id))
        )
    }
    private struct StartedPayload: Encodable { let collectionID: UUID }

    @Test func originalCollectorLogsArriveBeforeOwnedProcessCompletion() async throws {
        let (root, files, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipts = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try Data("{\"tokens\":42}\n".utf8).write(
            to: receipts.appendingPathComponent("synthetic.jsonl"))
        let script = try #require(
            MachineResources.url(forResource: "usage-snapshot", withExtension: "py"))
        var finished = false
        let service = MachineUsageCollectionService(files: files) { _, _ in
            let sink = MachineUsageProgressContext.output
            let result = try await CLICommandRunner.runSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [
                        "-c", "import runpy,sys,time; runpy.run_path(sys.argv[1]); time.sleep(0.5)",
                        script.path,
                    ],
                    environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], timeout: 5,
                    maximumOutputBytes: 1_048_576, terminatesProcessGroup: true),
                streamsWhileRunning: true, onStandardOutputLine: { _ in },
                onStandardErrorLine: { sink?($0, true) })
            #expect(result.terminationStatus == 0)
            try MachineUsageReceiptSnapshot.validate(result.standardOutputData)
            let object = try #require(
                JSONSerialization.jsonObject(with: result.standardOutputData) as? [String: Any])
            let snapshots = try #require(object["files"] as? [[String: Any]])
            #expect(snapshots.count == 1)
            #expect(snapshots.first?["path"] as? String == ".codex/sessions/synthetic.jsonl")
            finished = true
            return self.document
        }
        let id = try await start(service, machine: machine)
        var cursor: UInt64 = 0
        var logs = Data()
        var receipt: MachineUsageCollectionDescriptor?
        var observedWhileRunning = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while receipt == nil, ContinuousClock.now < deadline {
            let frame = try await read(service, id: id, sequence: cursor)
            cursor = frame.nextSequence
            if !frame.chunks.isEmpty && !finished { observedWhileRunning = true }
            for chunk in frame.chunks {
                #expect(chunk.channel == "stderr"); logs.append(chunk.data)
            }
            receipt = frame.receipt
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedWhileRunning)
        #expect(
            String(decoding: logs, as: UTF8.self).contains(
                "Scanning receipt source .codex/sessions"))
        #expect(
            String(decoding: logs, as: UTF8.self).contains(
                "Snapshot contains 1 receipts (14 bytes)"))
        let descriptor = try #require(receipt)
        #expect(descriptor.sha256 == MachineUsageReceiptSnapshot.hash(document))
        #expect(descriptor.byteCount == document.count)
        await #expect(throws: ExtensionPeerError.self) {
            try await read(service, id: id, sequence: 0)
        }
        try await cancel(service, id: id)
        await service.shutdownAndWait()
    }

    @Test func cancellationDrainsCollectorAndRejectsStaleForeignAndDisabledReads() async throws {
        let (root, files, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var entered = false
        var drained = false
        let service = MachineUsageCollectionService(files: files) { _, _ in
            entered = true
            defer { drained = true }
            _ = try await CLICommandRunner.runSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf 'collector waiting\\n' >&2; sleep 30"],
                    environment: ["PATH": "/usr/bin:/bin"], timeout: 35,
                    maximumOutputBytes: 1024, terminatesProcessGroup: true),
                streamsWhileRunning: true, onStandardOutputLine: { _ in },
                onStandardErrorLine: { _ in })
            return self.document
        }
        let id = try await start(service, machine: machine)
        for _ in 0..<100 where !entered { await Task.yield() }
        #expect(entered)
        await #expect(throws: ExtensionPeerError.self) { try await read(service, id: UUID()) }
        try await cancel(service, id: id)
        #expect(drained)
        await #expect(throws: ExtensionPeerError.self) { try await read(service, id: id) }
        await service.shutdownAndWait()
        await #expect(throws: ExtensionPeerError.self) {
            try await start(service, machine: machine)
        }
    }

    @Test func asyncJobsKeepCapacityUntilCancellationAndExpireWithSavedIdentity() async throws {
        let (root, files, machine) = fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 0)
        var drained = 0
        let service = MachineUsageCollectionService(files: files, now: { clock }) { _, _ in
            defer { drained += 1 }
            try await Task.sleep(for: .seconds(30))
            return self.document
        }
        let first = try await start(service, machine: machine)
        let second = try await start(service, machine: machine)
        for _ in 0..<100 { await Task.yield() }
        await #expect(throws: ExtensionPeerError.self) {
            try await start(service, machine: machine)
        }
        clock = clock.addingTimeInterval(61)
        _ = try? await read(service, id: first)
        for _ in 0..<100 { await Task.yield() }
        #expect(drained == 2)
        await #expect(throws: ExtensionPeerError.self) { try await read(service, id: second) }
        let replacement = try await start(service, machine: machine)
        for _ in 0..<100 { await Task.yield() }
        var changed = machine
        changed.host = "replacement.invalid"
        MachineRegistry.update(changed, files)
        await #expect(throws: ExtensionPeerError.self) { try await read(service, id: replacement) }
        await service.shutdownAndWait()
        #expect(drained == 3)
    }

    @Test func progressBoundsExactCursorAndActualFailure() throws {
        let stream = MachineUsageProgress()
        let id = UUID()
        for _ in 0..<20 { stream.receive(String(repeating: "x", count: 65_535), error: true) }
        var cursor: UInt64 = 0
        var received = 0
        var state = MachineUsageProgress.State.running
        while state == .running {
            let frame = try stream.read(id: id, sequence: cursor)
            #expect(frame.chunks.count <= 64)
            #expect(frame.chunks.reduce(0) { $0 + $1.data.count } <= 262_144)
            received += frame.chunks.reduce(0) { $0 + $1.data.count }
            cursor = frame.nextSequence
            state = frame.state
        }
        #expect(state == .overflow && received == 1_048_576)
        #expect(throws: ExtensionPeerError.self) { try stream.read(id: id, sequence: 0) }
        let failure = MachineUsageProgress()
        failure.receive("collector error", error: true)
        failure.finish(error: ExtensionPeerError.rejected("actual failure"))
        let frame = try failure.read(id: id, sequence: 0)
        #expect(frame.state == .failed && frame.receipt == nil)
        #expect(frame.chunks.first?.data == Data("collector error\n".utf8))
    }
}
