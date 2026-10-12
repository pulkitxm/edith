import Foundation
#if !SURFACE_OWNERSHIP_CHECKS
import Testing
@testable import EdithExtensionSupport
#endif

@MainActor private final class PendingSurfaceReplies {
    let entered = AsyncStream<Int>.makeStream()
    private var pending: [CheckedContinuation<Data, Never>] = []
    private(set) var calls = 0
    private(set) var returned = 0

    func execute() async throws -> Data {
        calls += 1
        let call = calls
        let data = await withCheckedContinuation { continuation in
            pending.append(continuation)
            entered.continuation.yield(call)
        }
        returned += 1
        return data
    }

    func release() throws {
        let data = try SurfaceSnapshot(providerID: "music").encoded()
        let owned = pending
        pending.removeAll()
        for continuation in owned { continuation.resume(returning: data) }
    }
}

@MainActor enum SurfaceSnapshotClientOwnershipChecks {
    static func run() async throws {
        try await retiredVersionWaitsForActualReturn()
        try await callerCancellationWaitsForActualReturn()
        try await retiredWorkRemainsBoundedAcrossReplacements()
        try await stoppedClientNeverReopens()
    }

    private static func retiredVersionWaitsForActualReturn() async throws {
        let replies = PendingSurfaceReplies()
        var entered = replies.entered.stream.makeAsyncIterator()
        var versions = ["music": "1"]
        let client = SurfaceSnapshotClient(activeVersions: { versions }) { _, _, _ in
            try await replies.execute()
        }
        let request = Task { @MainActor in
            try await client.snapshot(providerID: "music", target: .home, tile: .init(.music))
        }
        let entering = await entered.next()
        precondition(entering == 1)
        precondition(client.pendingCount == 1)
        versions = [:]
        client.retain(activeVersions: versions)
        precondition(client.pendingCount == 0 && client.versions.isEmpty)
        let started = AsyncStream<Void>.makeStream()
        var joining = started.stream.makeAsyncIterator()
        var completed = false
        let drain = Task { @MainActor in
            started.continuation.yield()
            await client.shutdownAndWait()
            completed = true
        }
        _ = await joining.next()
        precondition(!completed && replies.returned == 0)
        try replies.release()
        await drain.value
        precondition(completed && replies.returned == 1)
        try await expectRejected(request)
    }

    private static func callerCancellationWaitsForActualReturn() async throws {
        let replies = PendingSurfaceReplies()
        var entered = replies.entered.stream.makeAsyncIterator()
        let client = SurfaceSnapshotClient(activeVersions: { ["music": "1"] }) { _, _, _ in
            try await replies.execute()
        }
        let request = Task { @MainActor in
            try await client.snapshot(providerID: "music", target: .home, tile: .init(.music))
        }
        let entering = await entered.next()
        precondition(entering == 1)
        request.cancel()
        client.shutdown()
        precondition(client.pendingCount == 0)
        let started = AsyncStream<Void>.makeStream()
        var joining = started.stream.makeAsyncIterator()
        var completed = false
        let drain = Task { @MainActor in
            started.continuation.yield()
            await client.shutdownAndWait()
            completed = true
        }
        _ = await joining.next()
        precondition(!completed)
        try replies.release()
        await drain.value
        precondition(completed && replies.returned == 1)
        try await expectRejected(request)
        await client.shutdownAndWait()
    }

    private static func retiredWorkRemainsBoundedAcrossReplacements() async throws {
        let replies = PendingSurfaceReplies()
        var entered = replies.entered.stream.makeAsyncIterator()
        var versions = ["music": "1"]
        let client = SurfaceSnapshotClient(activeVersions: { versions }) { _, _, _ in
            try await replies.execute()
        }
        var requests: [Task<SurfaceSnapshot, Error>] = []
        for index in 1...32 {
            requests.append(
                Task { @MainActor in
                    try await client.snapshot(
                        providerID: "music", target: .home, tile: .init(.music))
                })
            let entering = await entered.next()
            precondition(entering == index)
            versions = ["music": String(index + 1)]
            client.retain(activeVersions: versions)
            precondition(client.pendingCount == 0 && client.versions == versions)
        }
        do {
            _ = try await client.snapshot(providerID: "music", target: .home, tile: .init(.music))
            throw CheckFailure.expectedRejection
        } catch CheckFailure.expectedRejection { throw CheckFailure.expectedRejection } catch {}
        precondition(replies.calls == 32)
        let started = AsyncStream<Void>.makeStream()
        var joining = started.stream.makeAsyncIterator()
        var completed = false
        let drain = Task { @MainActor in
            started.continuation.yield()
            await client.shutdownAndWait()
            completed = true
        }
        _ = await joining.next()
        precondition(!completed && replies.returned == 0)
        try replies.release()
        await drain.value
        precondition(completed && replies.returned == 32)
        for request in requests { try await expectRejected(request) }
    }

    private static func stoppedClientNeverReopens() async throws {
        let replies = PendingSurfaceReplies()
        let client = SurfaceSnapshotClient(activeVersions: { ["music": "1"] }) { _, _, _ in
            try await replies.execute()
        }
        client.shutdown()
        client.retain(activeVersions: ["music": "2"])
        await client.shutdownAndWait()
        do {
            _ = try await client.snapshot(providerID: "music", target: .home, tile: .init(.music))
            throw CheckFailure.expectedRejection
        } catch CheckFailure.expectedRejection { throw CheckFailure.expectedRejection } catch {}
        precondition(client.pendingCount == 0 && client.versions.isEmpty && replies.calls == 0)
    }

    private enum CheckFailure: Error { case expectedRejection }

    private static func expectRejected(_ request: Task<SurfaceSnapshot, Error>) async throws {
        switch await request.result {
        case .success: throw CheckFailure.expectedRejection
        case .failure: break
        }
    }
}

#if SURFACE_OWNERSHIP_CHECKS
@main struct SurfaceSnapshotClientOwnershipRunner {
    static func main() async throws {
        try await SurfaceSnapshotClientOwnershipChecks.run()
        print("four actual surface client retained ownership groups passed")
    }
}
#else
@MainActor @Suite struct SurfaceSnapshotClientOwnershipTests {
    @Test func cancelledRemoteOwnersJoinBeforeLifecycleCompletion() async throws {
        try await SurfaceSnapshotClientOwnershipChecks.run()
    }
}
#endif
