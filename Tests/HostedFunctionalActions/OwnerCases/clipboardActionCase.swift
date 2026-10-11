import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import ClipboardExtension

@MainActor
final class ClipboardActionCase: HostedFunctionalActionCase {
    static let owner = "clipboard"
    static let activationOperation = "clipboard.mutate"
    private let transport: HostedFunctionalActionTransport
    private let model: ClipboardHistoryModel
    private static let recordID = "functional-clipboard"

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let client = ClipboardClient { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
        model = ClipboardHistoryModel(client: client, observesNotifications: false)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let baseline = try await readState(context: context, pinned: true)
        model.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.entries.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard model.entries.count == 1, model.entries.first?.id == Self.recordID,
            model.entries.first?.preview == "Synthetic clipboard content"
        else { throw HostedFunctionalActionError.invalid }
        if model.entries[0].pinned {
            let count = transport.originalInvocationCount
            model.mutate(.init(.unpin, ids: [Self.recordID]))
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
            while model.isSaving, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !model.isSaving, model.error == nil else { throw HostedFunctionalActionError.invalid }
            let changed = try await readState(context: context, pinned: false)
            guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        } else { throw HostedFunctionalActionError.invalid }
        let count = transport.originalInvocationCount
        model.mutate(.init(.pin, ids: [Self.recordID]))
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        while model.isSaving, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !model.isSaving, model.error == nil,
            try await readState(context: context, pinned: true) == baseline
        else { throw HostedFunctionalActionError.invalid }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, pinned: true)
    }

    private func readState(context: HostedFunctionalActionContext, pinned: Bool) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative(
            "clipboard.snapshot", payload: ClipboardMessage.encode(ClipboardSnapshotRequest()))
        let snapshot = try ClipboardMessage.decode(ClipboardSnapshot.self, from: bytes)
        guard snapshot.total == 1, snapshot.entries.count == 1, let entry = snapshot.entries.first,
            entry.id == Self.recordID, entry.preview == "Synthetic clipboard content", entry.pinned == pinned
        else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { await model.shutdown() }
}
