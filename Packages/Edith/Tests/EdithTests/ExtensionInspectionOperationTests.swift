import Foundation
import Testing

@testable import EdithCLI
@testable import EdithCore
@testable import EdithKit

@Suite struct ExtensionInspectionOperationTests {
    @Test func everyInspectionLeafHasOneTypedReadDescriptor() {
        let expected: [ExtensionInspectionOperation: [String]] = [
            .list: ["extensions", "ls"],
            .info: ["extensions", "info"],
            .status: ["extensions", "status"],
            .verify: ["extensions", "verify"],
            .doctor: ["extensions", "doctor"],
        ]

        #expect(ExtensionInspectionOperation.allCases.count == expected.count)
        for operation in ExtensionInspectionOperation.allCases {
            #expect(operation.descriptor.cli == expected[operation])
            #expect(operation.descriptor.effect == .read)
            #expect(!operation.descriptor.requiresPreview)
            #expect(
                UserOperationCatalog.descriptor(id: operation.descriptor.id) == operation.descriptor
            )
        }
    }

    @Test func centerPreservesRegistryOrderAndRunsOnlyRequestedReports() async throws {
        let entries = Array(ExtensionRegistry.entries.prefix(2))
        let center = center(entries: entries)

        let list = try await center.execute(.list)
        #expect(list.items.map(\.entry.id) == entries.map(\.id))
        #expect(list.items.allSatisfy { $0.report == nil })

        let info = try await center.execute(.info, id: entries[0].defaultsKey.uppercased())
        #expect(info.items.map(\.entry.id) == [entries[0].id])
        #expect(info.items[0].report == nil)

        let status = try await center.execute(.status)
        #expect(status.items.map(\.entry.id) == entries.map(\.id))
        #expect(status.items.allSatisfy { $0.report?.state.phase == .disabled })

        let verify = try await center.execute(.verify, id: entries[1].id.uppercased())
        #expect(verify.items.map(\.entry.id) == [entries[1].id])
        #expect(verify.items[0].report?.state.phase == .disabled)

        let doctor = try await center.execute(.doctor, id: entries[0].id)
        #expect(doctor.items.map(\.entry.id) == [entries[0].id])
        #expect(doctor.items[0].report?.state.phase == .disabled)
    }

    @Test func centerRejectsUnknownAndInvalidArgumentShapes() async {
        let entries = Array(ExtensionRegistry.entries.prefix(2))
        let center = center(entries: entries)

        await #expect(throws: ExtensionInspectionError.self) {
            _ = try await center.execute(.verify, id: "missing")
        }
        await #expect(throws: ExtensionInspectionError.self) {
            _ = try await center.execute(.verify)
        }
        await #expect(throws: ExtensionInspectionError.self) {
            _ = try await center.execute(.list, id: entries[0].id)
        }
    }

    @Test func modalAndCLIUseTheSharedInspectionCenter() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let pane = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "Edith/Features/Settings/Views/ExtensionsPane.swift"),
            encoding: .utf8)
        let coordinator = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "EdithKit/Features/Extensions/Services/ExtensionMutationCenter.swift"),
            encoding: .utf8)
        let cli = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "EdithCLI/Commands/ExtensionCommands.swift"),
            encoding: .utf8)

        #expect(pane.contains("inspectionCenter.list().map(\\.entry)"))
        #expect(pane.contains("inspectionCenter.info(entry).entry"))
        #expect(pane.contains("readiness.refresh(.verify)"))
        #expect(pane.contains("readiness.refresh(.status)"))
        #expect(coordinator.contains("inspectionCenter.inspect(entry, operation: operation)"))
        for operation in ExtensionInspectionOperation.allCases {
            #expect(cli.contains("ExtensionLookup.inspect(.\(operation.caseName)"))
        }
    }

    private func center(entries: [ExtensionRegistryEntry]) -> ExtensionInspectionCenter {
        let environment = ExtensionLifecycleProbeEnvironment(
            isEnabled: { _ in false }, grantedPermissions: { [:] },
            toolReadiness: { _ in .uninstalled }, helperRunning: { false },
            platformCapabilities: .macOS, machineCount: { 0 },
            adapterReadiness: { _ in nil })
        return ExtensionInspectionCenter(
            entries: entries, isEnabled: { _ in false },
            probe: ExtensionLifecycleProbe(environment: environment))
    }
}

private extension ExtensionInspectionOperation {
    var caseName: String {
        switch self {
        case .list: "list"
        case .info: "info"
        case .status: "status"
        case .verify: "verify"
        case .doctor: "doctor"
        }
    }
}
