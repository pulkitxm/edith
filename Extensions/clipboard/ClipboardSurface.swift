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
        let arranged = Array(
            ClipboardActions.arrange(
                selected, pinToTop: ClipboardActions.pinToTopPreference()
            ).prefix(tile.itemLimit))
        let showRows = tile.shows("items") && (field.map(tile.shows) ?? true)
        let previews = showRows && tile.shows("previews") ? await thumbnails(arranged) : [:]
        try Task.checkCancellation()
        let rows = arranged.map { entry in
            let category = ClipboardCategory(entry)
            let title = Self.bounded(entry.displayPreview, bytes: 768)
            return SurfaceDataRow(
                entry.id, sourceID: category.id,
                title: title.isEmpty ? category.title : title,
                detail: Self.bounded(
                    [
                        entry.sourceApp,
                        entry.lastCopiedAt.formatted(date: .abbreviated, time: .shortened),
                    ].compactMap { $0 }.joined(separator: " · "), bytes: 512),
                value: entry.pinned ? "Pinned" : "", icon: category.symbol, field: field,
                actions: [
                    .init("copy/" + entry.id, "Copy", "doc.on.doc", field: field),
                    .init(
                        "pin/" + entry.id, entry.pinned ? "Unpin" : "Pin",
                        entry.pinned ? "pin.slash" : "pin", field: field),
                    .init("delete/" + entry.id, "Delete", "trash", field: field),
                ], thumbnail: previews[entry.id])
        }
        return .init(
            providerID: "clipboard",
            metrics: field.map({ tile.shows($0) }) == false
                ? []
                : [
                    .init("total", "Clips", "\(selected.count)"),
                    .init("pinned", "Pinned", "\(selected.filter(\.pinned).count)"),
                ], rows: rows,
            sources: ClipboardCategory.allCases.map { .init($0.id, $0.title) },
            message: selected.isEmpty ? "No matching clipboard history" : nil, updatedAt: Date())
    }

    private func thumbnails(_ entries: [ClipboardEntry]) async -> [String: SurfaceThumbnail] {
        let candidates = Array(entries.filter { $0.kind == .image || $0.kind == .file }.prefix(8))
        guard !candidates.isEmpty else { return [:] }
        let client = client
        return await withTaskGroup(of: (String, Data?).self) { group in
            for entry in candidates {
                group.addTask {
                    do {
                        let data = try await client.thumbnail(id: entry.id).data
                        return (entry.id, data)
                    } catch {
                        return (entry.id, nil)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(350))
                return ("", nil)
            }
            var result: [String: SurfaceThumbnail] = [:]
            var completed = 0
            var bytes = 0
            for await (id, data) in group {
                guard !id.isEmpty, !Task.isCancelled else { group.cancelAll(); break }
                completed += 1
                if let data, bytes + data.count <= 192 << 10 {
                    let preview = SurfaceThumbnail(
                        data: data, accessibilityLabel: "Copied content preview", field: "previews")
                    do {
                        try preview.validate()
                        result[id] = preview; bytes += data.count
                    } catch {}
                }
                if completed == candidates.count { group.cancelAll(); break }
            }
            return result
        }
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= bytes else { break }
            result.unicodeScalars.append(scalar); count += size
        }
        return result
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
