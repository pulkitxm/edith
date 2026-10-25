import EdithExtensionSupport
@testable import LidAwakeExtension
import Foundation
import Testing

@Suite struct LidAwakeOperationTests {
    @Test func descriptorsAreUniqueAndRegisteredForEveryCLILeaf() {
        let descriptors = LidAwakeOperation.allCases.map(\.descriptor)

        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.cli.first == "lid-awake" })
        #expect(
            Set(descriptors.map { $0.cli.last }) == [
                "status", "on", "off", "battery", "restore-on-quit",
            ])
    }

    @Test func runtimeActionsRetainTheirExactWireRequests() throws {
        for request in [
            LidAwakeRequest.status, .on(.indefinite), .off, .enableExtension, .disableExtension,
        ] {
            #expect(
                LidAwakeRequest(runtimePayload: try #require(request.runtimePayload)) == request)
        }
    }

    @Test func destructiveDescriptorsAndPreviewsStayAligned() {
        let destructive = LidAwakeOperation.allCases.filter {
            $0.descriptor.effect == .destructive
        }

        #expect(destructive == [.on, .restoreOnQuit])
        #expect(destructive.allSatisfy { $0.descriptor.requiresPreview })
        #expect(LidAwakeOperationExecution.preview(for: .on(.indefinite))?.operation == .on)
        #expect(
            LidAwakeOperationExecution.preview(for: .setRestoreOnQuit(false))?.operation
                == .restoreOnQuit)
        #expect(LidAwakeOperationExecution.preview(for: .off) == nil)
        #expect(LidAwakeOperationExecution.preview(for: .setRestoreOnQuit(true)) == nil)
    }

    @Test func settingExecutionAcceptsOnlyTypedSettings() throws {
        let suite = "test.lidawake.operations.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(
            LidAwakeOperationExecution.applySetting(
                .setBatteryThreshold(25), defaults: defaults))
        #expect(defaults.integer(forKey: LidAwakeState.batteryThresholdKey) == 25)
        #expect(
            LidAwakeOperationExecution.applySetting(
                .setRestoreOnQuit(false), defaults: defaults))
        #expect(!LidAwakeState.restoresOnQuit(defaults))
        #expect(
            !LidAwakeOperationExecution.applySetting(
                .setBatteryThreshold(101), defaults: defaults))
        #expect(!LidAwakeOperationExecution.applySetting(.off, defaults: defaults))
    }
}
