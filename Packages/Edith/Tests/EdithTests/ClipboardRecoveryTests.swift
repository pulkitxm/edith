import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct ClipboardRecoveryTests {
    @MainActor @Test func backgroundFailureRecoversWithoutOpeningMutationAlert() async throws {
        let transport = ClipboardRecoveryTransport()
        let store = ClipboardStore(
            client: .init(send: { try await transport.send($0, $1) }),
            capturesPasteboard: false)
        defer { store.shutdown() }
        try await wait { store.refreshError != nil }
        #expect(store.mutationError == nil)
        store.dismissMutationError()
        await transport.recover()
        try await wait { store.refreshError == nil && store.entries.count == 1 }
        #expect(store.mutationError == nil)
        store.delete(store.entries[0].id)
        try await wait { store.mutationError != nil && store.entries.count == 1 }
        #expect(store.refreshError == nil)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private actor ClipboardRecoveryTransport {
    private var available = false

    func recover() { available = true }

    func send(_ operation: String, _ payload: Data) throws -> Data {
        guard available, operation == AgentClipboardOperation.snapshot else {
            throw AgentError(.unavailable, "The background agent did not answer in time.")
        }
        let entry = ClipboardEntry(
            sha256: "fixture", types: ["public.text"], ext: "txt",
            sourceApp: nil, sourceBundleID: nil, size: 7, preview: "fixture")
        return try AgentPayload.encode(
            ClipboardSnapshot(entries: [entry], revision: "fixture", total: 1))
    }
}
