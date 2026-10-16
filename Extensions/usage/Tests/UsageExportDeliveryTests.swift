import CoreGraphics
import EdithExtensionSupport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageExportDeliveryTests {
    @Test func originalDeckDeliversActualPNGThroughOwningEngineAndAtomicFileWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("card.png")
        try Data("prior content".utf8).write(to: target)
        var copied: Data?
        var selectedNames: [String] = []
        let exports = UsageExportDelivery(
            chooseURL: {
                selectedNames.append($0); return target
            }, copy: { copied = $0 })
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            Issue.record("Export delivery must not start a collector")
            throw ExtensionPeerError.unavailable
        }
        let commands = UsageUICommands(controller: controller, directory: root, exports: exports)
        let client = UsageUIClient { try await commands.execute($0, payload: $1) }
        let deck = UsageExportDeck(
            snapshot: .init(days: [], agentCount: 0, repositoryCount: 0),
            delivery: { try await client.deliverExport($0, filename: $1, save: $2) })
        let callback = try #require(deck.delivery)
        let bytes = try png()
        #expect(bytes.count > 65_536)
        let filename = deck.filename(for: .activity)
        #expect(try await callback(bytes, filename, true) == "Saved card.png")
        #expect(try Data(contentsOf: target) == bytes)
        #expect(selectedNames == [filename] && copied == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["card.png"])
        #expect(try await callback(bytes, filename, false) == "Copied image")
        #expect(copied == bytes && selectedNames == [filename])
        #expect(deck.cards == UsageShareCard.allCases)
        client.stop()
        await commands.shutdownAndWait()
        await controller.shutdown()
    }

    @Test func invalidReceiptsChunksAndArtworkCannotReachDelivery() async throws {
        var delivered = false
        let exports = UsageExportDelivery(
            chooseURL: { _ in
                delivered = true; return nil
            }, copy: { _ in delivered = true })
        let bytes = try png()
        let id = try await begin(exports, data: bytes, hash: String(repeating: "0", count: 64))
        await #expect(throws: ExtensionPeerError.self) {
            try await exports.execute(
                "usage.ui.export.chunk",
                payload: object(["id": id.uuidString, "offset": 1, "data": "AA=="]))
        }
        try await upload(exports, id: id, data: bytes)
        await #expect(throws: ExtensionPeerError.self) {
            try await exports.execute("usage.ui.export.deliver", payload: identity(id))
        }
        let truncated = Data(bytes.prefix(100))
        let malformed = try await begin(exports, data: truncated)
        try await upload(exports, id: malformed, data: truncated)
        await #expect(throws: ExtensionPeerError.self) {
            try await exports.execute("usage.ui.export.deliver", payload: identity(malformed))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await exports.execute(
                "usage.ui.export.begin",
                payload: object([
                    "byteCount": bytes.count, "sha256": UsageMachinesPeer.hash(bytes),
                    "filename": "../card.png", "save": true,
                ]))
        }
        let cancelled = try await begin(exports, data: bytes)
        _ = try await exports.execute("usage.ui.export.cancel", payload: identity(cancelled))
        await #expect(throws: ExtensionPeerError.self) {
            try await upload(exports, id: cancelled, data: bytes)
        }
        #expect(!delivered)
        await exports.stopAndWait()
    }

    @Test(arguments: [false, true])
    func cancellingOrStoppingDeliveryPreventsLateFileWrite(stopping: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("card.png")
        let original = Data("retained original".utf8)
        try original.write(to: target)
        let gate = UsageExportSelectionGate()
        let exports = UsageExportDelivery(
            chooseURL: { _ in
                await gate.wait(); return target
            },
            copy: { _ in Issue.record("Save delivery attempted a clipboard action") })
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            Issue.record("Export delivery must not start a collector")
            throw ExtensionPeerError.unavailable
        }
        let commands = UsageUICommands(controller: controller, directory: root, exports: exports)
        let client = UsageUIClient { try await commands.execute($0, payload: $1) }
        let bytes = try png()
        let request = Task {
            try await client.deliverExport(
                bytes, filename: UsageShareCard.activity.filenameStem + ".png", save: true)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.waiting && ContinuousClock.now < deadline { await Task.yield() }
        try #require(gate.waiting)
        if stopping { client.stop(); commands.shutdown() } else { request.cancel() }
        gate.resume()
        await #expect(throws: (any Error).self) { try await request.value }
        await commands.shutdownAndWait()
        #expect(try Data(contentsOf: target) == original)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.deliverExport(bytes, filename: "../other.png", save: true)
        }
        await controller.shutdown()
    }

    private func begin(_ exports: UsageExportDelivery, data: Data, hash: String? = nil) async throws
        -> UUID
    {
        try await JSONDecoder().decode(
            UUID.self,
            from: exports.execute(
                "usage.ui.export.begin",
                payload: object([
                    "byteCount": data.count, "sha256": hash ?? UsageMachinesPeer.hash(data),
                    "filename": UsageShareCard.activity.filenameStem + ".png", "save": true,
                ])))
    }

    private func upload(_ exports: UsageExportDelivery, id: UUID, data: Data) async throws {
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            _ = try await exports.execute(
                "usage.ui.export.chunk",
                payload: object([
                    "id": id.uuidString, "offset": offset,
                    "data": data.subdata(in: offset..<min(data.count, offset + 65_536))
                        .base64EncodedString(),
                ]))
        }
    }

    private func identity(_ id: UUID) throws -> Data { try object(["id": id.uuidString]) }
    private func object(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func png() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 2_400, height: 1_600, bitsPerComponent: 8, bytesPerRow: 9_600,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: 15_360_000)
        var value: UInt32 = 42
        for offset in stride(from: 0, to: 15_360_000, by: 4) {
            value = value &* 1_664_525 &+ 1_013_904_223
            pixels[offset] = UInt8(truncatingIfNeeded: value >> 24)
            pixels[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
            pixels[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
            pixels[offset + 3] = 255
        }
        let image = try #require(context.makeImage())
        let result = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return result as Data
    }
}

@MainActor private final class UsageExportSelectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
