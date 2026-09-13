import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

private final class CaptureSessionProbe: CaptureScreenshotCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var cancellationCount = 0

    var started: Bool {
        lock.withLock { continuation != nil }
    }

    var cancellations: Int {
        lock.withLock { cancellationCount }
    }

    func capture() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func cancel() {
        let active = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            cancellationCount += 1
            defer { continuation = nil }
            return continuation
        }
        active?.resume(throwing: CaptureScreenshotError.cancelled)
    }
}

@Suite(.serialized) @MainActor struct CaptureToolsStoreTests {
    @Test func missingPermissionRequestsAccessWithoutStartingCapture() {
        let session = CaptureSessionProbe()
        var requests = 0
        let store = CaptureToolsStore(
            session: session, screenCaptureGranted: { false },
            requestScreenCapture: { requests += 1 })
        defer { store.shutdown() }

        store.start(.read)

        #expect(requests == 1)
        #expect(!session.started)
        #expect(!store.inProgress)
        #expect(store.errorMessage != nil)
    }

    @Test func cancellationStopsTheSessionAndClearsRuntimeState() async {
        let session = CaptureSessionProbe()
        let store = CaptureToolsStore(
            session: session, screenCaptureGranted: { true }, requestScreenCapture: {})
        defer { store.shutdown() }

        store.start(.screenshot)
        for _ in 0..<50 where !session.started { await Task.yield() }
        store.cancel()
        await Task.yield()

        #expect(session.started == false)
        #expect(session.cancellations == 1)
        #expect(!store.inProgress)
        #expect(store.errorMessage == nil)
    }

    @Test func shutdownCancelsAnActiveSession() async {
        let session = CaptureSessionProbe()
        let store = CaptureToolsStore(
            session: session, screenCaptureGranted: { true }, requestScreenCapture: {})

        store.start(.read)
        for _ in 0..<50 where !session.started { await Task.yield() }
        store.shutdown()
        await Task.yield()

        #expect(session.started == false)
        #expect(session.cancellations == 1)
        #expect(!store.inProgress)
    }
}
