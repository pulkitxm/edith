import Foundation
import Testing

@testable import EdithKit

@Suite struct LidAwakeOperationTests {
    @Test func descriptorsAreUniqueAndRegisteredForEveryCLILeaf() {
        let descriptors = LidAwakeOperation.allCases.map(\.descriptor)

        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.cli.first == "lid-awake" })
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
    }

    @Test func catalogCarriesTheFiveExactLidAwakeUIInvocations() {
        let operationIDs = Set(LidAwakeOperation.allCases.map(\.descriptor.id))
        let actual = Set(
            UserInterfaceActionCatalog.actions
                .filter { operationIDs.contains($0.operation.id) }
                .map { [$0.surface, $0.action] + $0.cli })

        #expect(
            actual
                == [
                    [
                        "Lid Awake controls", "inspect runtime state", "lid-awake", "status",
                    ],
                    [
                        "Lid Awake controls", "keep running with the lid closed", "lid-awake",
                        "on", "--yes",
                    ],
                    [
                        "Lid Awake controls", "restore normal lid-close sleep", "lid-awake",
                        "off",
                    ],
                    [
                        "Lid Awake settings", "set the low-battery pause floor", "lid-awake",
                        "battery", "20",
                    ],
                    [
                        "Lid Awake settings", "leave sleep disabled after quitting", "lid-awake",
                        "restore-on-quit", "false", "--yes",
                    ],
                ])
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
