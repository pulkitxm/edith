@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite @MainActor struct MachineUsageCompletionTests {
    private struct Started: Codable { let collectionID: UUID }
    private struct Chunk: Decodable { let offset: Int; let data: Data; let finished: Bool }
    private let document = Data(
        "{\"schemaVersion\":8,\"generatedAt\":\"2026-10-10T00:00:00Z\",\"sources\":[],\"daily\":[],\"sessions\":[],\"totals\":{}}"
            .utf8)

    private func request(_ machine: Machine, force: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "machineID": machine.id.uuidString, "force": force,
        ])
    }

    @Test func completedCollectorPublishesActualReceiptAndCachedIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = MachineRegistry.Files(machines: root.appendingPathComponent("machines.json"))
        let machine = Machine(name: "synthetic", host: "synthetic.invalid")
        MachineRegistry.add(machine, files)
        var calls = 0
        let service = MachineUsageCollectionService(files: files) { _, _ in
            calls += 1
            let output = try #require(MachineUsageProgressContext.output)
            output("actual collector completed", true)
            return document
        }
        let id = try JSONDecoder().decode(
            Started.self,
            from: await service.execute("machines.usage.start", payload: request(machine)))
        for _ in 0..<100 where calls == 0 { await Task.yield() }
        let frame = try JSONDecoder().decode(
            MachineUsageProgress.Frame.self,
            from: await service.execute(
                "machines.usage.progress",
                payload: JSONSerialization.data(
                    withJSONObject: ["collectionID": id.collectionID.uuidString, "sequence": 0])))
        #expect(frame.state == .completed)
        #expect(frame.chunks.first?.data == Data("actual collector completed\n".utf8))
        let receipt = try #require(frame.receipt)
        #expect(receipt.byteCount == document.count)
        #expect(receipt.sha256 == MachineUsageReceiptSnapshot.hash(document))
        let cached = try JSONDecoder().decode(
            MachineUsageCollectionDescriptor.self,
            from: await service.execute(
                "machines.usage.collect", payload: request(machine, force: false)))
        #expect(cached.collectionID == receipt.collectionID)
        #expect(calls == 1)
        let chunk = try JSONDecoder().decode(
            Chunk.self,
            from: await service.execute(
                "machines.usage.result",
                payload: JSONSerialization.data(
                    withJSONObject: [
                        "collectionID": receipt.collectionID.uuidString, "offset": 0,
                        "maximumBytes": 262_144,
                    ])))
        #expect(chunk.offset == 0 && chunk.finished && chunk.data == document)
        _ = try await service.execute("machines.usage.cancel", payload: JSONEncoder().encode(id))
        await #expect(throws: ExtensionPeerError.self) {
            try await service.execute(
                "machines.usage.result",
                payload: JSONSerialization.data(
                    withJSONObject: [
                        "collectionID": receipt.collectionID.uuidString, "offset": 0,
                        "maximumBytes": 262_144,
                    ]))
        }
        await service.shutdownAndWait()
    }

    @Test func directAndProgressCollectorsShareOwnedCapacityAndDrainBeforeReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = MachineRegistry.Files(machines: root.appendingPathComponent("machines.json"))
        let machine = Machine(name: "synthetic", host: "synthetic.invalid")
        MachineRegistry.add(machine, files)
        var entered = 0
        var drained = 0
        let service = MachineUsageCollectionService(files: files) { _, _ in
            entered += 1
            defer { drained += 1 }
            try await Task.sleep(for: .seconds(30))
            return document
        }
        let payload = try request(machine)
        let direct = Task { try await service.execute("machines.usage.collect", payload: payload) }
        for _ in 0..<100 where entered == 0 { await Task.yield() }
        let progress = try JSONDecoder().decode(
            Started.self, from: await service.execute("machines.usage.start", payload: payload))
        for _ in 0..<100 where entered < 2 { await Task.yield() }
        #expect(entered == 2)
        await #expect(throws: ExtensionPeerError.self) {
            try await service.execute("machines.usage.start", payload: payload)
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await service.execute("machines.usage.collect", payload: payload)
        }
        _ = try await service.execute(
            "machines.usage.cancel", payload: JSONEncoder().encode(progress))
        #expect(drained == 1)
        direct.cancel()
        _ = try? await direct.value
        #expect(drained == 2)
        let replacement = try JSONDecoder().decode(
            Started.self, from: await service.execute("machines.usage.start", payload: payload))
        for _ in 0..<100 where entered < 3 { await Task.yield() }
        #expect(entered == 3)
        _ = try await service.execute(
            "machines.usage.cancel", payload: JSONEncoder().encode(replacement))
        #expect(drained == 3)
        await service.shutdownAndWait()
    }

    @Test func retiredProgressCannotPublishALateReceipt() throws {
        let progress = MachineUsageProgress()
        progress.receive("collector running", error: true)
        progress.cancel()
        let receipt = MachineUsageCollectionDescriptor(
            collectionID: UUID(), byteCount: document.count,
            sha256: MachineUsageReceiptSnapshot.hash(document), generatedAt: "2026-10-10T00:00:00Z")
        #expect(!progress.finish(receipt: receipt))
        #expect(progress.isFinished)
        let frame = try progress.read(id: UUID(), sequence: 0)
        #expect(frame.state == .cancelled)
        #expect(frame.receipt == nil && frame.chunks.isEmpty)
    }

}
