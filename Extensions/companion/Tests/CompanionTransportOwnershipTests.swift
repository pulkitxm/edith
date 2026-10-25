import Foundation
import Testing

@testable import CompanionExtension

@MainActor
struct CompanionTransportOwnershipTests {
    @Test func closingEitherWindowPreservesTheOtherRemoteConnection() async throws {
        let transport = CompanionTransport()
        let firstID = UUID(), secondID = UUID()
        let first = CompanionUIBridge(invoke: { _, _ in Data("first".utf8) })
        let second = CompanionUIBridge(invoke: { _, _ in Data("second".utf8) })
        transport.configureRemote(first, owner: firstID)
        transport.configureRemote(second, owner: secondID)
        transport.releaseRemote(secondID)
        #expect(try await transport.remoteBridge?.invoke("fixture", Data()) == Data("first".utf8))
        transport.configureRemote(second, owner: secondID)
        transport.releaseRemote(firstID)
        #expect(try await transport.remoteBridge?.invoke("fixture", Data()) == Data("second".utf8))
        transport.releaseRemote(secondID)
        #expect(transport.remoteBridge == nil)
    }

    @Test func remoteRequestsResumeAfterTheLastWindowCloses() async throws {
        let transport = CompanionTransport()
        let worker = CompanionWorker(transport: CompanionTransport())
        let engine = CompanionUIEngine(
            worker: worker, endpoint: { URL(string: "http://fixture.invalid:4820")! },
            read: { request in
                (
                    Data("synthetic response".utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "text/plain"])!
                )
            })
        let request = URLRequest(
            url: URL(string: "http://fixture.invalid/v1/episodes/synthetic/media")!)
        let first = CompanionUIBridge(invoke: { try await engine.execute($0, payload: $1) })
        #expect(transport.configureRemote(first))
        #expect(try await transport.data(for: request).0 == Data("synthetic response".utf8))
        await transport.closeAndWait()
        await first.stopAndWait()
        let second = CompanionUIBridge(invoke: { try await engine.execute($0, payload: $1) })
        #expect(transport.configureRemote(second))
        #expect(try await transport.data(for: request).0 == Data("synthetic response".utf8))
        await transport.closeAndWait()
        await second.stopAndWait()
        await engine.shutdown()
        await worker.shutdown()
    }

    @Test func engineRequestsResumeAfterTransportShutdown() async throws {
        let transport = CompanionTransport()
        #expect(transport.open())
        #expect(try await transport.producers.perform { 1 } == 1)
        await transport.closeAndWait()
        #expect(transport.open())
        #expect(try await transport.producers.perform { 2 } == 2)
        await transport.closeAndWait()
    }

    @Test func reopeningWaitsForCancelledRequestsToReturn() async throws {
        let transport = CompanionTransport()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let task = try #require(
            transport.producers.launch {
                started.continuation.yield(())
                await withCheckedContinuation { continuation in
                    Task {
                        for await _ in release.stream { break }
                        continuation.resume()
                    }
                }
            })
        for await _ in started.stream { break }
        transport.close()
        #expect(!transport.open())
        let bridge = CompanionUIBridge(invoke: { _, _ in Data() })
        #expect(!transport.configureRemote(bridge))
        #expect(!transport.producers.reopen())
        release.continuation.yield(())
        await task.value
        await transport.closeAndWait()
        #expect(transport.configureRemote(bridge))
        #expect(try await transport.producers.perform { 3 } == 3)
        await transport.closeAndWait()
        started.continuation.finish()
        release.continuation.finish()
    }
}
