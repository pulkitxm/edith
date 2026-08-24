import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CompanionSettingsOperationTests {
    @Test func everyOperationHasAUniqueCatalogEntryAndExactUIPlacement() {
        let operations = CompanionSettingsOperation.allCases
        let descriptors = operations.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == operations.count)
        #expect(Set(descriptors.map(\.cli)).count == operations.count)
        #expect(Set(operations.map(\.uiPlacement)).count == operations.count)
        for operation in operations {
            #expect(
                UserOperationCatalog.descriptor(id: operation.descriptor.id)
                    == operation.descriptor)
            #expect(
                UserOperationCatalog.descriptor(cli: operation.descriptor.cli)
                    == operation.descriptor)
            #expect(operation.uiPlacement.hasPrefix("Companion settings > "))
        }
    }

    @Test func destructiveOperationsDeclareConcretePreviewTargets() {
        let destructive = CompanionSettingsOperation.allCases.filter {
            $0.descriptor.effect == .destructive
        }
        #expect(destructive == [.wipe, .dbReindex, .dbRebuildDerived])
        for operation in destructive {
            #expect(operation.descriptor.requiresPreview)
            #expect(!operation.previewTargets.isEmpty)
        }
        for operation in CompanionSettingsOperation.allCases
        where !destructive.contains(operation) {
            #expect(!operation.descriptor.requiresPreview)
            #expect(operation.previewTargets.isEmpty)
        }
    }

    @Test func connectorUpdatesRequireOneExplicitValue() throws {
        #expect(throws: CompanionSettingsOperationError.noConnectorTokens) {
            try CompanionConnectorTokenUpdate(github: nil, notion: nil)
        }
        let clear = try CompanionConnectorTokenUpdate(github: "", notion: nil)
        #expect(clear.github == "")
        #expect(clear.notion == nil)
    }

    @Test func reasonUpdatesValidateProviderAndRequireAChange() throws {
        #expect(throws: CompanionSettingsOperationError.noReasonChanges) {
            try CompanionReasonConfigurationUpdate(
                provider: nil, url: nil, model: nil, apiKey: nil)
        }
        #expect(throws: CompanionSettingsOperationError.unsupportedReasonProvider("local")) {
            try CompanionReasonConfigurationUpdate(
                provider: "local", url: nil, model: nil, apiKey: nil)
        }
        let clear = try CompanionReasonConfigurationUpdate(
            provider: "", url: nil, model: nil, apiKey: nil)
        #expect(clear.provider == "")
    }

    @Test func connectorImportsRejectUnknownSourcesBeforeReadingAFile() async {
        let execution = CompanionSettingsOperationExecution(
            client: CompanionClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        await #expect(throws: CompanionSettingsOperationError.unsupportedConnector("github")) {
            try await execution.importConnector(
                source: "github", from: URL(fileURLWithPath: "/does/not/exist"))
        }
    }

    @Test func connectorImportsReportUnreadableFilesBeforeCallingTheBackend() async {
        let execution = CompanionSettingsOperationExecution(
            client: CompanionClient(baseURL: URL(string: "http://127.0.0.1:1")!))
        do {
            _ = try await execution.importConnector(
                source: "music", from: URL(fileURLWithPath: "/does/not/exist"))
            Issue.record("expected an unreadable file error")
        } catch let error as CompanionSettingsOperationError {
            guard case .unreadableFile(let path, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(path == "/does/not/exist")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite struct CompanionSettingsOperationCLITests {
    @Test func connectorSetUsesSharedValidation() async {
        let result = await CLIProbe.run(["companion", "connectors", "set"])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("at least one connector token"))
        #expect(result.stdout.isEmpty)
    }

    @Test func connectorImportRejectsUnknownSourcesBeforeReading() async {
        let result = await CLIProbe.run([
            "companion", "connectors", "import", "github", "/does/not/exist",
        ])
        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("github is not supported"))
        #expect(result.stdout.isEmpty)
    }

    @Test func reasonSetUsesSharedValidation() async {
        let empty = await CLIProbe.run(["companion", "reason", "set"])
        #expect(empty.code == ExitCodes.usage)
        #expect(empty.stderr.contains("at least one reasoning setting"))

        let provider = await CLIProbe.run([
            "companion", "reason", "set", "--provider", "local",
        ])
        #expect(provider.code == ExitCodes.usage)
        #expect(provider.stderr.contains("local is not supported"))
    }

    @Test func completionMetadataMarksDerivedMaintenanceAsPreviewed() {
        for command in ["reindex", "rebuild-derived"] {
            let node = CommandTree.node(at: ["companion", "db", command])
            #expect(node?.destructivePolicy == .previewThenYes)
            #expect(node?.options.contains("--yes") == true)
        }
    }
}
