import CoreGraphics
import EdithExtensionSupport
import Foundation
import ImageIO
import Testing
@testable import BifrostExtension

private actor BifrostPreviewPeer {
    let image: Data
    let slow: Bool
    var requests: [UUID] = []
    var cancellations: [UUID] = []
    init(image: Data, slow: Bool = false) { self.image = image; self.slow = slow }
    func send(_ command: String, _ payload: Data) async throws -> Data {
        if command == "clipboard.thumbnail.cancel" {
            cancellations.append(try JSONDecoder().decode(UUID.self, from: payload)); return Data()
        }
        struct Request: Decodable { let id: UUID; let entryID: String }
        let request = try JSONDecoder().decode(Request.self, from: payload)
        requests.append(request.id)
        if slow { try await Task.sleep(for: .seconds(5)) }
        return try JSONEncoder().encode(["data": image])
    }
    var counts: (Int, Int) { (requests.count, cancellations.count) }
    var cancelledMatchingRequests: Bool { Set(requests) == Set(cancellations) }
}

@Suite @MainActor struct BifrostClipboardPreviewTests {
    @Test func boundedPeerPreviewsReplaceCrossExtensionFileAccess() async throws {
        let image = try png()
        let peer = BifrostPreviewPeer(image: image)
        let previews = BifrostClipboardPreviewService(
            send: { try await peer.send($0, $1) }, privacy: { [:] })
        #expect(await previews.load("synthetic-clip") == image)
        let entry = BifrostClipboardEntry(
            id: "synthetic-clip", sha256: "test", types: ["public.png"], ext: "png",
            sourceApp: "Fixture Notes", sourceBundleID: "test.notes", createdAt: Date(),
            lastCopiedAt: Date(), size: image.count, preview: nil, pinned: false)
        let result = try #require(
            BifrostClipboardFeed.results(entries: [entry], query: "", scope: "all", now: Date())
                .first)
        #expect(result.detail?.clipboardPreviewID == entry.id)
        #expect(result.detail?.imagePath == nil)
        await previews.shutdown()
    }

    @Test func malformedAndOversizedPreviewsNeverReachTheView() async {
        for bytes in [Data("not an image".utf8), Data(repeating: 1, count: 131_073)] {
            let peer = BifrostPreviewPeer(image: bytes)
            let previews = BifrostClipboardPreviewService(
                send: { try await peer.send($0, $1) }, privacy: { [:] })
            #expect(await previews.load("synthetic-clip") == nil)
            await previews.shutdown()
        }
    }

    @Test func disablingDrainsOwnedReadsAndCancelsTheMatchingProviderRequest() async throws {
        let peer = BifrostPreviewPeer(image: try png(), slow: true)
        let previews = BifrostClipboardPreviewService(
            send: { try await peer.send($0, $1) }, privacy: { [:] })
        let read = Task { await previews.load("synthetic-clip") }
        while await peer.counts.0 == 0 { await Task.yield() }
        await previews.shutdown()
        #expect(await read.value == nil)
        #expect(await peer.cancelledMatchingRequests)
        #expect(await previews.load("synthetic-clip") == nil)
        #expect(await peer.counts.0 == 1)
    }

    @Test func presenterPrivacyBlocksPreviewReads() async {
        let peer = BifrostPreviewPeer(image: Data())
        let previews = BifrostClipboardPreviewService(
            send: { try await peer.send($0, $1) }, privacy: { ["active": "1"] })
        #expect(await previews.load("synthetic-clip") == nil)
        #expect(await peer.counts.0 == 0)
        await previews.shutdown()
    }

    private func png() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1));
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
