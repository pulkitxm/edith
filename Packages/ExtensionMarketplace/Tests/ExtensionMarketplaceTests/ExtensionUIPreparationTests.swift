import Foundation
import EdithExtensionCore
import Testing

@testable import ExtensionMarketplace

@Suite @MainActor
struct ExtensionUIPreparationTests {
    @Test func acknowledgedPreparationUsesOnlyTheOwnedPresentation() async throws {
        let object = Preparation()
        let id = UUID()
        let task = Task {
            try await ExtensionBundleRuntime.preparePresentationToClose(
                object: object, presentationID: id)
        }
        while object.callback == nil { await Task.yield() }
        #expect(object.presentation == id.uuidString)
        object.callback?(nil)
        try await task.value
    }

    @Test func rejectedPreparationDoesNotReportAcknowledgment() async throws {
        let object = Preparation()
        let task = Task {
            try await ExtensionBundleRuntime.preparePresentationToClose(
                object: object, presentationID: UUID())
        }
        while object.callback == nil { await Task.yield() }
        object.callback?("Synthetic preferences remain unsaved")
        await #expect(throws: MarketplaceError.invalidBundle) { try await task.value }
    }

    @Test func cancellationFinishesEvenWhenTheOptionalCallbackNeverResponds() async throws {
        let object = Preparation()
        let task = Task {
            try await ExtensionBundleRuntime.preparePresentationToClose(
                object: object, presentationID: UUID())
        }
        while object.callback == nil { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        object.callback?(nil)
    }

    @Test func runtimesWithoutPendingUIStateRequireNoAdditionalOperation() async throws {
        try await ExtensionBundleRuntime.preparePresentationToClose(
            object: IdlePreparation(), presentationID: UUID())
    }

    @MainActor private final class Preparation: IdlePreparation {
        override var supportsPresentationPreparation: Bool { true }
        var presentation: String?
        var callback: ((NSString?) -> Void)?
        override func preparePresentationToClose(_ id: UUID) async -> String? {
            presentation = id.uuidString
            return await withCheckedContinuation { continuation in
                callback = { continuation.resume(returning: $0 as String?) }
            }
        }
    }
}

@MainActor private class IdlePreparation: ExtensionRuntimeProtocol {
    var runtimeAPIVersion: Int { ExtensionRuntimeAPI.version }
    var supportsDisablePreparation: Bool { false }
    var supportsPresentationPreparation: Bool { false }
    func dispatch(_ request: ExtensionRuntimeRequest) -> ExtensionRuntimeResponse { .result(true) }
    func invokeCommand(_ command: String, token: UUID, payload: Data) async throws -> Data {
        Data()
    }
    func suspend() async {}
    func prepareForDisable() async throws {}
    func prepareForStop() async {}
    func preparePresentationToClose(_ presentation: UUID) async -> String? { nil }
}
