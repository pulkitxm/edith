import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct UsageProjectActionModelTests {
    private enum Failure: LocalizedError {
        case unavailable

        var errorDescription: String? { "Clipboard unavailable." }
    }

    @Test func failuresBecomeActionableAndSuccessClearsThem() {
        var copied = ""
        var shouldFail = true
        let model = UsageProjectActionModel(
            copyChatID: { value in
                if shouldFail { throw Failure.unavailable }
                copied = value
                return UsageProjectOperationResult(
                    operationID: UsageProjectOperation.copyChatID.descriptor.id,
                    repositoryID: nil, value: value)
            })

        model.copyChatID("chat-42")
        #expect(model.failureMessage == "Clipboard unavailable. Try again.")

        shouldFail = false
        model.copyChatID("chat-42")
        #expect(copied == "chat-42")
        #expect(model.failureMessage == nil)
    }

    @Test func dismissRemovesTheVisibleFailure() {
        let model = UsageProjectActionModel(
            openRepository: { _ in throw Failure.unavailable })
        let target = UsageProjectTarget(
            repositoryID: "github.com/acme/edith", repositoryName: "edith",
            repositoryURL: "https://github.com/acme/edith")

        model.openRepository(target)
        #expect(model.failureMessage != nil)
        model.dismissFailure()
        #expect(model.failureMessage == nil)
    }
}
