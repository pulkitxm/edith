import EdithExtensionCore
import Foundation
import Testing

@testable import ExtensionMarketplace

@MainActor @Suite struct ExtensionCommandCancellationTests {
    @Test func cancellationBeforeRuntimeAdmissionPreventsDeferredSideEffects() async throws {
        let runtime = DeferredCommandRuntime()
        let token = UUID()
        var cancelledTokens: [UUID] = []
        let invocation = Task {
            try await ExtensionBundleRuntime.command(
                object: runtime, token: token, command: "synthetic.change", payload: Data()
            ) { cancelledTokens.append(token) }
        }
        try await wait { runtime.waiting }
        invocation.cancel()
        await #expect(throws: CancellationError.self) { try await invocation.value }
        try await wait { cancelledTokens == [token] }
        runtime.admit()
        try await wait { runtime.finished }
        #expect(runtime.sideEffects == 0)
        #expect(runtime.cancelled)
    }

    @Test func alreadyCancelledCallsNeverEnterTheRuntime() async throws {
        let runtime = DeferredCommandRuntime()
        let invocation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExtensionBundleRuntime.command(
                object: runtime, token: UUID(), command: "synthetic.change", payload: Data(),
                cancel: {})
        }
        await #expect(throws: CancellationError.self) { try await invocation.value }
        await Task.yield()
        #expect(!runtime.waiting && runtime.sideEffects == 0)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor private final class DeferredCommandRuntime: ExtensionRuntimeProtocol {
    var runtimeAPIVersion: Int { ExtensionRuntimeAPI.version }
    var supportsDisablePreparation: Bool { false }
    var supportsPresentationPreparation: Bool { false }
    private(set) var waiting = false
    private(set) var finished = false
    private(set) var cancelled = false
    private(set) var sideEffects = 0
    private var admission: CheckedContinuation<Void, Never>?

    func dispatch(_ request: ExtensionRuntimeRequest) -> ExtensionRuntimeResponse { .result(true) }

    func invokeCommand(_ command: String, token: UUID, payload: Data) async throws -> Data {
        waiting = true
        await withCheckedContinuation { admission = $0 }
        defer { finished = true }
        do { try Task.checkCancellation() } catch {
            cancelled = true
            throw error
        }
        sideEffects += 1
        return Data()
    }

    func admit() { admission?.resume(); admission = nil }
    func suspend() async {}
    func prepareForDisable() async throws {}
    func prepareForStop() async {}
    func preparePresentationToClose(_ presentation: UUID) async -> String? { nil }
}
