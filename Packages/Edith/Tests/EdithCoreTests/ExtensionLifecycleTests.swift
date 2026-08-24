import Foundation
import Testing

@testable import EdithCore

@Suite struct ExtensionLifecycleTests {
    @Test func everyRegistryEntryHasOneDescriptorInRegistryOrder() {
        #expect(
            ExtensionLifecycleCatalog.descriptors.map(\.id) == ExtensionRegistry.entries.map(\.id))
        #expect(ExtensionLifecycleCatalog.byID.count == ExtensionRegistry.entries.count)
    }

    @Test func everyDescriptorExplainsTheWholeLifecycle() {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for descriptor in ExtensionLifecycleCatalog.descriptors {
            #expect(!descriptor.value.isEmpty, "\(descriptor.id) has no value statement")
            #expect(!descriptor.workflows.isEmpty, "\(descriptor.id) has no workflow")
            #expect(!descriptor.prerequisites.isEmpty, "\(descriptor.id) has no prerequisite")
            #expect(!descriptor.cliExamples.isEmpty, "\(descriptor.id) has no CLI example")
            #expect(!descriptor.documentation.isEmpty, "\(descriptor.id) has no documentation")
            #expect(!descriptor.recovery.isEmpty, "\(descriptor.id) has no recovery action")
            #expect(!descriptor.verification.isEmpty, "\(descriptor.id) has no verification")
            #expect(descriptor.cliExamples.allSatisfy { $0.hasPrefix("ed ") })
            #expect(descriptor.documentation.allSatisfy { $0.path.hasPrefix("docs/") })
            #expect(
                descriptor.documentation.allSatisfy {
                    FileManager.default.fileExists(
                        atPath: repository.appendingPathComponent($0.path).path)
                },
                "\(descriptor.id) links to missing documentation")
            validate(descriptor.workflows, extensionID: descriptor.id, field: "workflow")
            validate(descriptor.prerequisites, extensionID: descriptor.id, field: "prerequisite")
            validate(descriptor.recovery, extensionID: descriptor.id, field: "recovery")
            validate(descriptor.verification, extensionID: descriptor.id, field: "verification")
        }
    }

    @Test func descriptorsAndStatesRoundTripThroughJSON() throws {
        let descriptor = try #require(ExtensionLifecycleCatalog.descriptor(for: "quinjet"))
        let descriptorData = try JSONEncoder().encode(descriptor)
        #expect(
            try JSONDecoder().decode(ExtensionLifecycleDescriptor.self, from: descriptorData)
                == descriptor)

        let state = ExtensionLifecycleState(
            extensionID: "quinjet", phase: .needsSetup, summary: "Quinjet is missing.",
            issues: [
                ExtensionLifecycleIssue(
                    id: "missing-tool", title: "Install Quinjet",
                    detail: "The quinjet executable is not on PATH.",
                    recoveryCommand: "ed tools install quinjet")
            ])
        let stateData = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ExtensionLifecycleState.self, from: stateData) == state)
    }

    @Test func preferenceStateDoesNotClaimReadiness() {
        #expect(
            ExtensionLifecycleState.preference(extensionID: "usage", enabled: false).phase
                == .disabled)
        #expect(
            ExtensionLifecycleState.preference(extensionID: "usage", enabled: true).phase
                == .enabled)
        #expect(
            ExtensionLifecycleState.preference(extensionID: "usage", enabled: false).runtimePhase
                == .uninstalled)
        #expect(
            ExtensionLifecycleState.loading(extensionID: "usage").runtimePhase == .loading)
        #expect(
            ExtensionRuntimePhase.allCases.map(\.rawValue) == [
                "installed", "uninstalled", "empty", "loading", "unsupported", "error",
            ])
    }

    @Test func reportsRoundTripWithStructuredChecks() throws {
        let report = ExtensionLifecycleReport(
            state: ExtensionLifecycleState(
                extensionID: "calendar", phase: .needsSetup, summary: "Calendar access is missing."),
            checks: [
                ExtensionLifecycleCheck(
                    id: "permission.calendar", title: "Calendar access", status: .failed,
                    detail: "Grant Calendar access.",
                    recoveryCommand: "ed permissions request calendar")
            ])
        let data = try JSONEncoder().encode(report)

        #expect(try JSONDecoder().decode(ExtensionLifecycleReport.self, from: data) == report)
        #expect(!report.verified)
    }

    private func validate(
        _ instructions: [ExtensionLifecycleInstruction], extensionID: String, field: String
    ) {
        #expect(
            Set(instructions.map(\.id)).count == instructions.count,
            "\(extensionID) has duplicate \(field) ids")
        for instruction in instructions {
            #expect(!instruction.title.isEmpty, "\(extensionID) has an untitled \(field)")
            #expect(!instruction.detail.isEmpty, "\(extensionID) has an unexplained \(field)")
            if let command = instruction.command {
                #expect(command.hasPrefix("ed "), "\(extensionID) has a non-ed \(field) command")
            }
        }
    }
}
