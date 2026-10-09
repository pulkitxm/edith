import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@Suite struct UsageMachinesProjectionTests {
    actor Transport {
        let data: Data
        var machine: Machine?
        var active = true
        var incorrectOffset = false
        init(data: Data, machine: Machine) { self.data = data; self.machine = machine }
        func disable() { active = false }
        func replaceMachine() { machine?.host = "changed.invalid" }
        func corruptOffset() { incorrectOffset = true }
        func invoke(_ command: String, payload: Data) throws -> Data {
            guard command == "machines.usage.snapshot.result" else {
                throw ExtensionPeerError.invalidRequest
            }
            let request = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let offset = request["offset"] as! Int
            let maximum = request["maximumBytes"] as! Int
            #expect(maximum <= 262_144)
            #expect(Set(request.keys) == ["collectionID", "offset", "maximumBytes"])
            let end = min(data.count, offset + maximum)
            return try JSONEncoder().encode(
                UsageMachinesPeer.Chunk(
                    offset: incorrectOffset ? offset + 1 : offset,
                    data: data.subdata(in: offset..<end), finished: end == data.count))
        }
    }
    actor SlowCollector {
        var started = false
        var cancelled = false
        func collect() async throws -> Data {
            started = true
            do { try await Task.sleep(for: .seconds(30)); return Data() } catch {
                cancelled = true; throw error
            }
        }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_791_504_000)
        func now() -> Date { lock.withLock { value } }
        func advance() { lock.withLock { value.addTimeInterval(901) } }
    }

    @Test func nativeProjectionReceiptsAreChunkedAndStableAcrossNewSnapshotIDs() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = sampleMachine()
        let snapshot = try fixture(machine)
        let transport = Transport(data: snapshot, machine: machine)
        let service = service(directory, transport: transport)
        var previous: Data?
        for _ in 0..<2 {
            let receipt = try JSONDecoder().decode(
                UsageMachinesPeer.Receipt.self,
                from: await service.execute(
                    "usage.machines.project", payload: request(machine, snapshot)))
            var result = Data()
            while result.count < receipt.byteCount {
                let chunk = try JSONDecoder().decode(
                    UsageMachinesPeer.Chunk.self,
                    from: await service.execute(
                        "usage.machines.result",
                        payload: object([
                            "collectionID": receipt.collectionID.uuidString, "offset": result.count,
                            "maximumBytes": 113,
                        ])))
                #expect(chunk.offset == result.count)
                #expect(chunk.data.count <= 113)
                result.append(chunk.data)
                #expect(chunk.finished == (result.count == receipt.byteCount))
            }
            #expect(UsageMachinesPeer.hash(result) == receipt.sha256)
            #expect(UsageHistory.isValidDocument(result))
            let totals = try UsageNativeJSON.object(result)["totals"] as! [String: Any]
            #expect(totals["tokens"] as? Double == 12)
            #expect(totals["cost"] as? Double == 1)
            let daily = try UsageNativeJSON.object(result)["daily"] as! [[String: Any]]
            let projects = daily.flatMap { $0["projects"] as? [[String: Any]] ?? [] }
            #expect(projects.first?["repositoryID"] as? String == "github.com/example/sample")
            if let previous {
                #expect(
                    try UsageNativeJSON.object(previous)["totals"] as? NSDictionary == totals
                        as NSDictionary)
            }
            previous = result
            _ = try await service.execute(
                "usage.machines.cancel",
                payload: object(["collectionID": receipt.collectionID.uuidString]))
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await service.execute(
                    "usage.machines.result",
                    payload: object([
                        "collectionID": receipt.collectionID.uuidString, "offset": 0,
                        "maximumBytes": 113,
                    ]))
            }
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.appendingPathComponent("remote-staging").path
            ).isEmpty)
        let archive = try UsageNativeArchive(
            dataDirectory: directory.appendingPathComponent(
                "remote-archives/" + machine.id.uuidString.lowercased()),
            remoteContext: .init(machineID: machine.id))
        #expect(try archive.events().count == 1)
        await service.shutdown()
    }

    @Test func malformedChecksumAndOffsetsNeverReachTheCollector() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = sampleMachine()
        let snapshot = try fixture(machine)
        let transport = Transport(data: snapshot, machine: machine)
        let service = service(
            directory, transport: transport,
            collector: { _, _, _ in
                Issue.record("Malformed snapshot reached collector"); return Data()
            })
        let invalid = UsageMachinesProjection.Snapshot(
            machineID: machine.id, collectionID: UUID(), byteCount: snapshot.count,
            sha256: String(repeating: "0", count: 64))
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.machines.project", payload: JSONEncoder().encode(invalid))
        }
        await transport.corruptOffset()
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.machines.project", payload: request(machine, snapshot))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await service.shutdown()
    }

    @Test func receiptAdmissionRejectsTraversalCredentialsUnknownFieldsAndMachineSubstitution()
        throws
    {
        let machine = sampleMachine()
        let valid = try fixture(machine)
        #expect(try UsageReceiptSnapshot.decode(valid, machineID: machine.id).files.count == 1)
        for path in [
            "../outside.json", "/outside.json", ".claude/.credentials.json", ".codex/auth.json",
            ".claude/projects/x/../outside.json", ".codex/sessions//outside.json",
            ".cursor/chats/secrets.json", ".ssh/config", ".claude/projects/x/record.txt",
        ] {
            var value = try UsageNativeJSON.object(valid)
            value["files"] = [
                [
                    "path": path, "modifiedAt": 1_800_000_000,
                    "data": Data("{}".utf8).base64EncodedString(),
                ]
            ]
            #expect(throws: ExtensionPeerError.self) {
                _ = try UsageReceiptSnapshot.decode(object(value), machineID: machine.id)
            }
        }
        var value = try UsageNativeJSON.object(valid)
        value["path"] = "/arbitrary"
        #expect(throws: ExtensionPeerError.self) {
            _ = try UsageReceiptSnapshot.decode(object(value), machineID: machine.id)
        }
        value = try UsageNativeJSON.object(valid)
        value["version"] = true
        #expect(throws: DecodingError.self) {
            _ = try UsageReceiptSnapshot.decode(object(value), machineID: machine.id)
        }
        #expect(throws: ExtensionPeerError.self) {
            _ = try UsageReceiptSnapshot.decode(valid, machineID: UUID())
        }
        value = try UsageNativeJSON.object(valid)
        value["files"] = (value["files"] as! [[String: Any]]) + (value["files"] as! [[String: Any]])
        #expect(throws: ExtensionPeerError.self) {
            _ = try UsageReceiptSnapshot.decode(object(value), machineID: machine.id)
        }
        value = try UsageNativeJSON.object(valid)
        value["files"] = [
            [
                "path": ".codex/config.toml", "modifiedAt": 1_800_000_000,
                "data": Data("service_tier = \"fast\"\n".utf8).base64EncodedString(),
            ]
        ]
        #expect(
            try UsageReceiptSnapshot.decode(object(value), machineID: machine.id).files.count == 1)
        value["files"] = [
            [
                "path": ".codex/config.toml", "modifiedAt": 1_800_000_000,
                "data": Data("api_key = \"fixture-private\"\n".utf8).base64EncodedString(),
            ]
        ]
        #expect(throws: ExtensionPeerError.self) {
            _ = try UsageReceiptSnapshot.decode(object(value), machineID: machine.id)
        }
    }

    @Test func unavailableChangedAndExpiredPeersCannotReadPreviouslyProjectedResults() async throws
    {
        for change in ["disabled", "registry", "expired"] {
            let directory = temporary()
            defer { try? FileManager.default.removeItem(at: directory) }
            let machine = sampleMachine()
            let snapshot = try fixture(machine)
            let transport = Transport(data: snapshot, machine: machine)
            let clock = Clock()
            let service = service(directory, transport: transport, clock: clock)
            let receipt = try JSONDecoder().decode(
                UsageMachinesPeer.Receipt.self,
                from: await service.execute(
                    "usage.machines.project", payload: request(machine, snapshot)))
            if change == "disabled" { await transport.disable() }
            if change == "registry" { await transport.replaceMachine() }
            if change == "expired" { clock.advance() }
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await service.execute(
                    "usage.machines.result",
                    payload: object([
                        "collectionID": receipt.collectionID.uuidString, "offset": 0,
                        "maximumBytes": 113,
                    ]))
            }
            await service.shutdown()
        }
    }

    @Test func parentCancellationAndShutdownDrainCollectorsAndRemovePrivateStages() async throws {
        for shutdown in [false, true] {
            let directory = temporary()
            defer { try? FileManager.default.removeItem(at: directory) }
            let machine = sampleMachine()
            let snapshot = try fixture(machine)
            let transport = Transport(data: snapshot, machine: machine)
            let collector = SlowCollector()
            let service = service(
                directory, transport: transport,
                collector: { _, _, _ in try await collector.collect() })
            let payload = try request(machine, snapshot)
            let task = Task {
                try await service.execute("usage.machines.project", payload: payload)
            }
            try await waitFor(collector)
            if shutdown { await service.shutdown() } else { task.cancel() }
            await #expect(throws: Error.self) { _ = try await task.value }
            #expect(await collector.cancelled)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: directory.appendingPathComponent("remote-staging").path
                ).isEmpty)
            await service.shutdown()
        }
    }

    @Test func duplicateMachineJobsAndArbitraryPathPayloadsAreRejected() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = sampleMachine()
        let snapshot = try fixture(machine)
        let transport = Transport(data: snapshot, machine: machine)
        let collector = SlowCollector()
        let service = service(
            directory, transport: transport, collector: { _, _, _ in try await collector.collect() }
        )
        let descriptor = UsageMachinesProjection.Snapshot(
            machineID: machine.id, collectionID: UUID(),
            byteCount: snapshot.count, sha256: UsageMachinesPeer.hash(snapshot))
        let payload = try JSONEncoder().encode(descriptor)
        let task = Task { try await service.execute("usage.machines.project", payload: payload) }
        try await waitFor(collector)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.machines.project", payload: request(machine, snapshot))
        }
        var arbitrary = try UsageNativeJSON.object(payload); arbitrary["path"] = "/arbitrary"
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute("usage.machines.project", payload: object(arbitrary))
        }
        _ = try await service.execute(
            "usage.machines.cancel",
            payload: object(["collectionID": descriptor.collectionID.uuidString]))
        await #expect(throws: Error.self) { _ = try await task.value }
        #expect(await collector.cancelled)
        await service.shutdown()
    }

    @Test func unsafeStagingParentsAndFailedCollectorsNeverLeaveSnapshotsOrResults() async throws {
        for symlink in [false, true] {
            let directory = temporary()
            defer { try? FileManager.default.removeItem(at: directory) }
            try UsageNativeFileIO.privateDirectory(directory)
            if symlink {
                let outside = directory.appendingPathComponent("outside")
                try UsageNativeFileIO.privateDirectory(outside)
                try FileManager.default.createSymbolicLink(
                    at: directory.appendingPathComponent("remote-staging"),
                    withDestinationURL: outside)
            }
            let machine = sampleMachine()
            let snapshot = try fixture(machine)
            let transport = Transport(data: snapshot, machine: machine)
            let service = service(
                directory, transport: transport,
                collector: { _, _, _ in throw CocoaError(.fileReadUnknown) })
            await #expect(throws: Error.self) {
                _ = try await service.execute(
                    "usage.machines.project", payload: request(machine, snapshot))
            }
            let location = directory.appendingPathComponent(symlink ? "outside" : "remote-staging")
            #expect(try FileManager.default.contentsOfDirectory(atPath: location.path).isEmpty)
            await service.shutdown()
        }
    }

    @Test func forgettingHistoryRemovesThePrivateArchiveAndPreventsDeletedReceiptsReturning()
        async throws
    {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = sampleMachine()
        let snapshot = try fixture(machine)
        let transport = Transport(data: snapshot, machine: machine)
        let service = service(directory, transport: transport)
        let receipt = try JSONDecoder().decode(
            UsageMachinesPeer.Receipt.self,
            from: await service.execute(
                "usage.machines.project", payload: request(machine, snapshot)))
        let chunk = try JSONDecoder().decode(
            UsageMachinesPeer.Chunk.self,
            from: await service.execute(
                "usage.machines.result",
                payload: object([
                    "collectionID": receipt.collectionID.uuidString, "offset": 0,
                    "maximumBytes": 262_144,
                ])))
        #expect(chunk.finished)
        let canonical = try UsageMachinesPeer.canonicalized(chunk.data, machine: machine)
        let cache = directory.appendingPathComponent(
            "machines/" + machine.id.uuidString.lowercased() + ".json")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsageDataFiles.write(canonical, to: cache)
        try UsageDataFiles.write(canonical, to: directory.appendingPathComponent("usage.json"))
        let otherArchive = directory.appendingPathComponent(
            "remote-archives/" + UUID().uuidString.lowercased())
        try UsageNativeFileIO.privateDirectory(otherArchive)
        try UsageDataFiles.write(
            Data("fixture-keep".utf8), to: otherArchive.appendingPathComponent("receipt"))
        try await service.forget(machineID: machine.id)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "remote-archives/" + machine.id.uuidString.lowercased()
                ).path))
        #expect(
            try UsageDataFiles.readRegularFile(at: otherArchive.appendingPathComponent("receipt"))
                == Data("fixture-keep".utf8))
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.machines.result",
                payload: object([
                    "collectionID": receipt.collectionID.uuidString, "offset": 0,
                    "maximumBytes": 113,
                ]))
        }
        let published = try #require(
            try UsageDataFiles.readRegularFile(at: directory.appendingPathComponent("usage.json")))
        #expect(UsageHistory.isValidDocument(published))
        #expect(
            (try UsageNativeJSON.object(published)["totals"] as! [String: Any])["tokens"] as? Double
                == 0)
        await service.shutdown()
        var empty = try UsageNativeJSON.object(snapshot); empty["files"] = []
        let emptySnapshot = try object(empty)
        let nextTransport = Transport(data: emptySnapshot, machine: machine)
        let next = self.service(directory, transport: nextTransport)
        let nextReceipt = try JSONDecoder().decode(
            UsageMachinesPeer.Receipt.self,
            from: await next.execute(
                "usage.machines.project", payload: request(machine, emptySnapshot)))
        let nextChunk = try JSONDecoder().decode(
            UsageMachinesPeer.Chunk.self,
            from: await next.execute(
                "usage.machines.result",
                payload: object([
                    "collectionID": nextReceipt.collectionID.uuidString, "offset": 0,
                    "maximumBytes": 262_144,
                ])))
        #expect(
            (try UsageNativeJSON.object(nextChunk.data)["totals"] as! [String: Any])["tokens"]
                as? Double == 0)
        await next.shutdown()
    }

    @Test func forgettingDrainsActiveCollectorsAndCannotDeleteThroughAnArchiveSymlink() async throws
    {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let machine = sampleMachine()
        let snapshot = try fixture(machine)
        let transport = Transport(data: snapshot, machine: machine)
        let slow = SlowCollector()
        let service = service(
            directory, transport: transport, collector: { _, _, _ in try await slow.collect() })
        let payload = try request(machine, snapshot)
        let task = Task { try await service.execute("usage.machines.project", payload: payload) }
        try await waitFor(slow)
        let archive = directory.appendingPathComponent(
            "remote-archives/" + machine.id.uuidString.lowercased())
        try UsageDataFiles.write(
            Data("fixture-delete".utf8), to: archive.appendingPathComponent("receipt"))
        try await service.forget(machineID: machine.id)
        await #expect(throws: Error.self) { _ = try await task.value }
        #expect(await slow.cancelled)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.appendingPathComponent("remote-staging").path
            ).isEmpty)
        let outside = directory.appendingPathComponent("outside")
        try UsageNativeFileIO.privateDirectory(outside)
        try UsageDataFiles.write(
            Data("fixture-keep".utf8), to: outside.appendingPathComponent("receipt"))
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
        await #expect(throws: UsageNativeFailure.self) {
            try await service.forget(machineID: machine.id)
        }
        #expect(
            try UsageDataFiles.readRegularFile(at: outside.appendingPathComponent("receipt"))
                == Data("fixture-keep".utf8))
        await service.shutdown()
    }

    private func service(
        _ directory: URL, transport: Transport, clock: Clock = Clock(),
        collector: UsageMachinesProjection.Collector? = nil
    ) -> UsageMachinesProjection {
        let peer = UsageMachinesPeer(
            active: { await transport.active },
            invoke: { try await transport.invoke($0, payload: $1) })
        return UsageMachinesProjection(
            directory: directory, currentPeer: { peer },
            currentMachine: { id in
                let machine = await transport.machine
                return machine?.id == id ? machine : nil
            }, now: { clock.now() },
            collector: collector ?? { home, archive, context in
                try await UsageNativeCollector.collectRemote(
                    home: home, dataDirectory: archive, context: context,
                    now: clock.now(), onEvent: { _ in })
            })
    }
    private func waitFor(_ collector: SlowCollector) async throws {
        for _ in 0..<100 {
            if await collector.started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderInvalidValue)
    }
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func sampleMachine() -> Machine {
        Machine(id: UUID(), name: "Sample machine", host: "sample.invalid")
    }
    private func request(_ machine: Machine, _ data: Data) throws -> Data {
        try JSONEncoder().encode(
            UsageMachinesProjection.Snapshot(
                machineID: machine.id,
                collectionID: UUID(), byteCount: data.count, sha256: UsageMachinesPeer.hash(data)))
    }
    private func object(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
    private func fixture(_ machine: Machine) throws -> Data {
        var journal = try object([
            "timestamp": "2026-10-09T01:00:00Z", "cwd": "/remote/projects/sample",
            "sessionId": "sample", "costUSD": 1,
            "message": [
                "model": "claude-sonnet-4-5", "usage": ["input_tokens": 10, "output_tokens": 2],
            ],
        ])
        journal.append(10)
        return try object([
            "version": 1,
            "context": [
                "machineID": machine.id.uuidString, "timeZone": "UTC",
                "projects": [
                    [
                        "cwd": "/remote/projects/sample", "root": "/remote/projects/sample",
                        "repositoryID": "github.com/example/sample",
                        "repositoryName": "Sample", "folderName": "sample", "worktree": "topic",
                    ]
                ],
            ],
            "files": [
                [
                    "path": ".claude/projects/sample/session.jsonl", "modifiedAt": 1_800_000_000,
                    "data": journal.base64EncodedString(),
                ]
            ],
        ])
    }
}
