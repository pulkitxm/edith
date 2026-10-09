import AppKit
import EdithExtensionSupport
import Foundation

@MainActor final class ClipboardSurface {
    private let client: ClipboardClient
    private let isStopped: @MainActor () -> Bool
    private let privacyValues: @MainActor () -> [String: String]
    private let copy: @MainActor (ClipboardCopyPayload) -> Void

    init(
        client: ClipboardClient, isStopped: @escaping @MainActor () -> Bool = { false },
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        },
        copy: @escaping @MainActor (ClipboardCopyPayload) -> Void = {
            ClipboardRepository.copyToPasteboard($0, pasteboard: .general)
        }
    ) {
        self.client = client; self.isStopped = isStopped
        self.privacyValues = privacyValues; self.copy = copy
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "clipboard", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) },
            perform: { try await self.perform($0) }, privacyValues: privacyValues)
    }

    private func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        let entries = try await client.entries()
        try Task.checkCancellation()
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        let field = tile.widget == .desk ? "clipboard" : nil
        let selected = entries.filter { tile.sourceIDs?.contains(ClipboardCategory($0).id) ?? true }
        let rows = ClipboardActions.arrange(
            selected, pinToTop: ClipboardActions.pinToTopPreference()
        )
        .prefix(tile.itemLimit).map { entry in
            let category = ClipboardCategory(entry)
            return SurfaceDataRow(
                entry.id, sourceID: category.id,
                title: entry.displayPreview.isEmpty ? category.title : entry.displayPreview,
                detail: [
                    entry.sourceApp,
                    entry.lastCopiedAt.formatted(date: .abbreviated, time: .shortened),
                ].compactMap { $0 }.joined(separator: " · "),
                value: entry.pinned ? "Pinned" : "", icon: category.symbol, field: field,
                actions: [
                    .init("copy/" + entry.id, "Copy", "doc.on.doc", field: field),
                    .init(
                        "pin/" + entry.id, entry.pinned ? "Unpin" : "Pin",
                        entry.pinned ? "pin.slash" : "pin", field: field),
                    .init("delete/" + entry.id, "Delete", "trash", field: field),
                ])
        }
        return .init(
            providerID: "clipboard",
            metrics: field.map({ tile.shows($0) }) == false
                ? [] : [.init("count", "Clips", "\(selected.count)")], rows: Array(rows),
            sources: ClipboardCategory.allCases.map { .init($0.id, $0.title) },
            message: selected.isEmpty ? "No matching clipboard history" : nil, updatedAt: Date())
    }

    private func perform(_ actionID: String) async throws {
        let parts = actionID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[1]) != nil, !isStopped() else {
            throw ExtensionPeerError.invalidRequest
        }
        switch parts[0] {
        case "copy":
            let plain = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
            let payload = try await client.copy(id: parts[1], plainTextOnly: plain)
            try Task.checkCancellation()
            guard !isStopped(),
                !SurfacePrivacyState.hides(.ability("clipboard"), values: privacyValues())
            else {
                throw ExtensionPeerError.invalidRequest
            }
            copy(payload)
            _ = try await client.mutate(.init(.copied, ids: [parts[1]]))
        case "pin":
            let current = try await client.entries()
            guard let entry = current.first(where: { $0.id == parts[1] }) else {
                throw ExtensionPeerError.invalidRequest
            }
            try Task.checkCancellation()
            guard !isStopped(),
                !SurfacePrivacyState.hides(.ability("clipboard"), values: privacyValues())
            else {
                throw ExtensionPeerError.invalidRequest
            }
            _ = try await client.mutate(.init(entry.pinned ? .unpin : .pin, ids: [entry.id]))
        case "delete":
            _ = try await client.mutate(.init(.delete, ids: [parts[1]]))
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
