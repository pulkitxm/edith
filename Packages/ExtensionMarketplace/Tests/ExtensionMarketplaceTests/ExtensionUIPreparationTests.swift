import Foundation
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
            object: NSObject(), presentationID: UUID())
    }

    @MainActor private final class Preparation: NSObject {
        var presentation: String?
        var callback: ((NSString?) -> Void)?
        @objc(prepareUIToClose:completion:)
        func prepareUIToClose(_ id: NSString, completion: @escaping (NSString?) -> Void) {
            presentation = id as String
            callback = completion
        }
    }
}
