import Foundation
import Testing
@testable import CameraDeployment

@Suite struct CameraMicrophoneRetirementTests {
    @Test func removingLoadedDriverRequiresRestartAndRetainsOwnershipForTheSameBoot() throws {
        var installed = true
        var removed = 0
        var saved: String?
        let retirement = CameraMicrophoneRetirement(
            boot: "synthetic-boot-a", pendingBoot: nil, installed: { installed },
            remove: {
                removed += 1; installed = false
            }, save: { saved = $0 })
        #expect(try retirement.retire())
        #expect(saved == "synthetic-boot-a")
        #expect(try retirement.retire())
        #expect(removed == 1)
    }
    @Test func freshBootCanReleaseRetiredDriverOwnership() throws {
        var saved: String? = "synthetic-boot-a"
        let retirement = CameraMicrophoneRetirement(
            boot: "synthetic-boot-b", pendingBoot: saved, installed: { false },
            remove: { Issue.record("An absent driver should not be removed") }, save: { saved = $0 }
        )
        #expect(try !retirement.retire())
        #expect(saved == nil)
    }
    @Test func removalFailurePersistsUncertainOwnershipAndRetriesSafely() throws {
        var attempts = 0
        var saved: String?
        let retirement = CameraMicrophoneRetirement(
            boot: "synthetic-boot-a", pendingBoot: nil, installed: { true },
            remove: {
                attempts += 1; if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
            }, save: { saved = $0 })
        #expect(throws: (any Error).self) { try retirement.retire() }
        #expect(saved == "synthetic-boot-a")
        #expect(try retirement.retire())
        #expect(attempts == 2)
    }
    @Test func journalFailureCannotRemoveDriverWithoutRetainingRestartState() {
        var removed = false
        let retirement = CameraMicrophoneRetirement(
            boot: "synthetic-boot-a", pendingBoot: nil, installed: { true },
            remove: { removed = true }, save: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: (any Error).self) { try retirement.retire() }
        #expect(!removed)
    }
}
