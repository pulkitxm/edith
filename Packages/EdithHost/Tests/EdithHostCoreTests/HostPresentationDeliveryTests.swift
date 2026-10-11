import Foundation
import Testing

@testable import EdithHostCore

@MainActor struct HostPresentationDeliveryTests {
    @Test func selectionCannotAcknowledgeAndReceiptRechecksItsLiveOwner() async throws {
        let receipt = HostPresentationDelivery(extensionID: "emoji", version: "1.0.0")
        #expect(throws: HostPresentationDeliveryError.unavailable) { try receipt.validate() }
        let owner = Owner()
        try receipt.receive(
            presentationID: receipt.id, extensionID: "emoji", version: "1.0.0",
            validate: {
                guard owner.current else { throw HostPresentationDeliveryError.rejected }
            })
        try await receipt.wait()
        owner.current = false
        #expect(throws: HostPresentationDeliveryError.rejected) { try receipt.validate() }
    }

    @MainActor private final class Owner {
        var current = true
    }

    @Test func failedDismissedForeignAndReplacedPresentationsNeverAcknowledge() async throws {
        for (id, owner, version) in [
            (UUID(), "clipboard", "1.0.0"), (UUID(), "emoji", "1.0.0"),
            (UUID(), "clipboard", "2.0.0"),
        ] {
            let receipt = HostPresentationDelivery(extensionID: "clipboard", version: "1.0.0")
            #expect(throws: HostPresentationDeliveryError.rejected) {
                try receipt.receive(
                    presentationID: id, extensionID: owner, version: version, validate: {})
            }
            receipt.reject()
            await #expect(throws: HostPresentationDeliveryError.rejected) {
                try await receipt.wait()
            }
        }
        let dismissed = HostPresentationDelivery(extensionID: "emoji", version: "1.0.0")
        try dismissed.receive(
            presentationID: dismissed.id, extensionID: "emoji", version: "1.0.0", validate: {})
        dismissed.reject()
        await #expect(throws: HostPresentationDeliveryError.rejected) { try await dismissed.wait() }
    }

    @Test func missingDeliveryTimesOutAndCancelledWaitCannotAdmitALateController() async throws {
        let missing = HostPresentationDelivery(extensionID: "emoji", version: "1.0.0")
        await #expect(throws: HostPresentationDeliveryError.timedOut) {
            try await missing.wait(timeout: .milliseconds(10))
        }
        let cancelled = HostPresentationDelivery(extensionID: "clipboard", version: "1.0.0")
        let task = Task { try await cancelled.wait() }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(throws: HostPresentationDeliveryError.rejected) {
            try cancelled.receive(
                presentationID: cancelled.id, extensionID: "clipboard", version: "1.0.0",
                validate: {})
        }
    }
}
