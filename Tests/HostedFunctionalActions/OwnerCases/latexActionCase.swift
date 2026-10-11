import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import LaTeXExtension

@MainActor
final class LaTeXActionCase: HostedFunctionalActionCase {
    static let owner = "latex"
    static let activationOperation = "latex.ui.action"
    private let transport: HostedFunctionalActionTransport
    private let model: LaTeXModel
    private static let draft = "\\documentclass{article}\n\\begin{document}\nSynthetic retained draft\n\\end{document}\n"

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        let context = transport.context
        guard context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let store = try context.ownedPath(named: "latex-projects", kind: "file")
        let bridge = LaTeXUIBridge { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
        model = LaTeXModel(store: LaTeXProjectStore(url: store), remote: bridge)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let baseline = try await readState(context: context, sourceText: Self.draft)
        await model.start()
        let source = try context.ownedPath(named: "latex-source", kind: "file")
        guard model.projects.count == 1, let project = model.projects.first,
            project.location == .disk, project.sourcePath == source.path,
            model.selectedID == project.id, model.original != nil, !model.busy
        else { throw HostedFunctionalActionError.invalid }
        let preceding = transport.originalInvocationCount
        let temporary = Self.draft + "\nSynthetic temporary edit\n"
        model.source = temporary
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: preceding)
        let changed = try await readState(context: context, sourceText: temporary)
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        let count = transport.originalInvocationCount
        model.source = Self.draft
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        guard try await readState(context: context, sourceText: Self.draft) == baseline else {
            throw HostedFunctionalActionError.invalid
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, sourceText: Self.draft)
    }

    private func readState(context: HostedFunctionalActionContext, sourceText: String) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let value = try JSONDecoder().decode(
            LaTeXUISnapshot.self, from: await transport.readAuthoritative("latex.ui.snapshot"))
        let source = try context.ownedPath(named: "latex-source", kind: "file")
        guard value.projects.count == 1, let project = value.projects.first,
            project.location == .disk, project.sourcePath == source.path,
            value.selectedID == project.id, value.source == sourceText, let original = value.original,
            value.pdfByteCount == 0, !value.busy, !value.buildingPDF
        else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LaTeXDraft(projectID: project.id, text: value.source, original: original))
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { await model.shutdown() }
}
