@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite @MainActor struct MachineUsageTransportTests {
    @MainActor private final class Fixture {
        enum Pause { case none, ssh, project, result }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let machine = Machine(
            name: "Synthetic Windows", host: "synthetic.invalid",
            createdAt: Date(timeIntervalSince1970: 1))
        let projectedID = UUID()
        let output: Data
        var files: MachineRegistry.Files {
            .init(machines: root.appendingPathComponent("machines.json"))
        }
        var transport: MachinePeerTransport!
        var pause: Pause = .none
        var entered: Pause = .none
        var snapshotID: UUID?
        var pending: Task<Data, Error>?
        var resultAvailable = false
        var calls: [String] = []
        var cancellations: [UUID] = []
        var snapshotChunks = 0
        var resultChunks = 0
        var corruptHash = false

        init() throws {
            output = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 8, "generatedAt": "2026-10-09T00:00:00Z",
                "sources": ["codex"], "daily": [], "sessions": [],
                "totals": ["inputTokens": 42], "padding": String(repeating: "x", count: 300_000),
            ])
            MachineRegistry.add(machine, files)
            transport = MachinePeerTransport(
                files: files, usagePlatform: { _ in .windows },
                usageRun: { [self] selected, command, input, timeout, maximum in
                    #expect(selected == machine)
                    #expect(
                        command
                            == (try MachineRemoteUsageOperation.command(
                                platform: .windows, force: true)))
                    #expect(input == (try MachineRemoteUsageOperation.input()))
                    #expect(timeout == 900 && maximum == 67_108_864)
                    entered = .ssh
                    if pause == .ssh { try await Task.sleep(for: .seconds(60)) }
                    let journal =
                        Data(
                            "{\"cwd\":\"C:\\\\Synthetic Projects\\\\Worktree\",\"tokens\":42}\n"
                                .utf8)
                        + Data(repeating: 32, count: 300_000)
                    let snapshot = try JSONSerialization.data(withJSONObject: [
                        "version": 1,
                        "files": [
                            [
                                "path": ".codex/sessions/mock.jsonl", "modifiedAt": 42.0,
                                "data": journal.base64EncodedString(),
                            ]
                        ],
                        "context": [
                            "projects": [
                                [
                                    "cwd": "C:\\Synthetic Projects\\Worktree",
                                    "root": "C:\\Synthetic Projects",
                                    "repositoryID": "example.com/mock",
                                    "repositoryName": "mock", "folderName": "Worktree",
                                ]
                            ], "timeZone": "UTC",
                        ],
                    ])
                    return SSHExecResult(status: 0, stdout: snapshot, stderr: Data())
                },
                usageInvoke: { [self] command, payload, timeout in
                    try await invoke(command, payload, timeout)
                })
        }

        func invoke(_ command: String, _ payload: Data, _ timeout: TimeInterval) async throws
            -> Data
        {
            calls.append(command)
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            switch command {
            case "usage.machines.project":
                #expect(Set(object.keys) == ["machineID", "collectionID", "byteCount", "sha256"])
                #expect(timeout == 900)
                let descriptor = try JSONDecoder().decode(
                    MachineUsageSnapshotDescriptor.self, from: payload)
                #expect(descriptor.machineID == machine.id)
                snapshotID = descriptor.collectionID
                var snapshot = Data()
                while snapshot.count < descriptor.byteCount {
                    let response = try transport.snapshots.execute(
                        "machines.usage.snapshot.result",
                        payload: request(descriptor.collectionID, snapshot.count))
                    let chunk = try JSONDecoder().decode(Chunk.self, from: response)
                    #expect(chunk.offset == snapshot.count && chunk.data.count <= 262_144)
                    snapshot.append(chunk.data); snapshotChunks += 1
                    #expect(chunk.finished == (snapshot.count == descriptor.byteCount))
                }
                #expect(MachineUsageReceiptSnapshot.hash(snapshot) == descriptor.sha256)
                let document = try #require(
                    JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
                #expect(Set(document.keys) == ["version", "files", "context"])
                let context = try #require(document["context"] as? [String: Any])
                #expect(context["machineID"] as? String == machine.id.uuidString)
                let projects = try #require(context["projects"] as? [[String: String]])
                #expect(projects.first?["cwd"] == "C:\\Synthetic Projects\\Worktree")
                #expect(projects.first?["root"] == "C:\\Synthetic Projects")
                entered = .project
                if pause == .project {
                    let job = Task.detached {
                        try await Task.sleep(for: .seconds(60)); return Data()
                    }
                    pending = job
                    _ = try await withTaskCancellationHandler {
                        try await job.value
                    } onCancel: {
                        job.cancel()
                    }
                }
                resultAvailable = true
                return try JSONSerialization.data(withJSONObject: [
                    "collectionID": projectedID.uuidString, "byteCount": output.count,
                    "sha256": corruptHash
                        ? String(repeating: "0", count: 64)
                        : MachineUsageReceiptSnapshot.hash(output),
                    "generatedAt": "2026-10-09T00:00:00Z",
                ])
            case "usage.machines.result":
                #expect(Set(object.keys) == ["collectionID", "offset", "maximumBytes"])
                #expect(timeout == 60 && resultAvailable)
                #expect(object["collectionID"] as? String == projectedID.uuidString)
                #expect(object["maximumBytes"] as? Int == 262_144)
                entered = .result
                if pause == .result { try await Task.sleep(for: .seconds(60)) }
                let offset = try #require(object["offset"] as? Int)
                let end = min(output.count, offset + 262_144); resultChunks += 1
                return try JSONEncoder().encode(
                    Chunk(
                        offset: offset,
                        data: output.subdata(in: offset..<end), finished: end == output.count))
            case "usage.machines.cancel":
                #expect(Set(object.keys) == ["collectionID"] && timeout == 15)
                #expect(!Task.isCancelled)
                let idText = try #require(object["collectionID"] as? String)
                let id = try #require(UUID(uuidString: idText))
                cancellations.append(id)
                if id == snapshotID {
                    pending?.cancel(); _ = try? await pending?.value; pending = nil
                } else {
                    #expect(id == projectedID && resultAvailable); resultAvailable = false
                }
                return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }

        func request(_ id: UUID, _ offset: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "collectionID": id.uuidString,
                "offset": offset, "maximumBytes": 262_144,
            ])
        }

        func invalidated() throws {
            #expect(pending == nil && !resultAvailable)
            if let snapshotID {
                #expect(throws: (any Error).self) {
                    try transport.snapshots.execute(
                        "machines.usage.snapshot.result", payload: request(snapshotID, 0))
                }
            }
        }

        func cleanup() async {
            await transport.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        struct Chunk: Codable { let offset: Int; let data: Data; let finished: Bool }
    }

    @Test func transportProjectsAndStreamsBothDirectionsThroughExactUsageDTOs() async throws {
        let fixture = try Fixture()
        let service = MachineUsageCollectionService(files: fixture.files) { machine, force in
            try await fixture.transport.collectUsage(machine, force: force)
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "machineID": fixture.machine.id.uuidString, "force": true,
        ])
        let raw = try await service.execute("machines.usage.collect", payload: payload)
        let descriptor = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let idText = try #require(descriptor["collectionID"] as? String)
        let id = try #require(UUID(uuidString: idText))
        var output = Data()
        while output.count < fixture.output.count {
            let chunk = try JSONDecoder().decode(
                Fixture.Chunk.self,
                from: await service.execute(
                    "machines.usage.result", payload: fixture.request(id, output.count)))
            output.append(chunk.data)
        }
        #expect(output == fixture.output)
        #expect(fixture.snapshotChunks == 2 && fixture.resultChunks == 2)
        #expect(fixture.cancellations == [fixture.projectedID])
        _ = try await service.execute(
            "machines.usage.cancel", payload: Data("{\"collectionID\":\"\(id)\"}".utf8))
        try fixture.invalidated()
        service.shutdown(); await fixture.cleanup()
    }

    @Test func cancellationWaitsForProjectionOrResultAndUsesTheCurrentCollectionID() async throws {
        for pause in [Fixture.Pause.ssh, .project, .result] {
            let fixture = try Fixture(); fixture.pause = pause
            let task = Task {
                try await fixture.transport.collectUsage(fixture.machine, force: true)
            }
            let deadline = Date().addingTimeInterval(5)
            while fixture.entered != pause && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(fixture.entered == pause)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            if pause == .ssh { #expect(fixture.calls.isEmpty && fixture.cancellations.isEmpty) }
            if pause == .project { #expect(fixture.cancellations == [fixture.snapshotID!]) }
            if pause == .result { #expect(fixture.cancellations == [fixture.projectedID]) }
            try fixture.invalidated(); await fixture.cleanup()
        }
    }

    @Test func corruptProjectedDocumentFailsAndReleasesBothOwners() async throws {
        let fixture = try Fixture(); fixture.corruptHash = true
        await #expect(throws: (any Error).self) {
            try await fixture.transport.collectUsage(fixture.machine, force: true)
        }
        #expect(fixture.cancellations == [fixture.projectedID])
        try fixture.invalidated(); await fixture.cleanup()
    }
}
