import AppKit
import EdithExtensionSupport
import Foundation

struct ColorPickerClipboardEntry: Decodable, Equatable {
    let id: String
    let ext: String
    let sourceApp: String?
    let lastCopiedAt: Date
    let preview: String?
    let pinned: Bool
}

enum ColorPickerSurface {
    static let pickMessage =
        "Pick a color from your screen. Enable Clipboard to include recent copied colors."
    static let emptyMessage = "No matching clipboard history"
    static let pickAction = SurfaceAction("pick", "Pick color", "eyedropper")

    static func isColor(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (4...64).contains(value.count) else { return false }
        if value.hasPrefix("#") {
            let digits = value.dropFirst()
            return [3, 4, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return false }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return false }
        let arguments = value[value.index(after: open)..<value.index(before: value.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
        return (3...4).contains(arguments.count)
            && arguments.allSatisfy {
                Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%°"))) != nil
            }
    }

    static func snapshot(
        tile: SurfaceTile, clipboardActive: Bool, pinToTop: Bool,
        entries: () async throws -> [ColorPickerClipboardEntry]
    ) async throws -> SurfaceSnapshot {
        guard clipboardActive else {
            return .init(providerID: "colorPicker", actions: [pickAction], message: pickMessage)
        }
        let colors = try await entries().filter { isColor($0.preview ?? "") }
        try Task.checkCancellation()
        let pinned = colors.filter(\.pinned).sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let loose = colors.filter { !$0.pinned }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let arranged = Array((pinToTop ? pinned + loose : loose + pinned).prefix(tile.itemLimit))
        let rows = arranged.map { entry in
            SurfaceDataRow(
                entry.id,
                title: bounded(
                    (entry.preview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                detail: [
                    entry.sourceApp,
                    entry.lastCopiedAt.formatted(date: .abbreviated, time: .shortened),
                ].compactMap { $0 }.joined(separator: " · "),
                value: entry.pinned ? "Pinned" : "", icon: "paintpalette",
                actions: [
                    .init("copy/" + entry.id, "Copy", "doc.on.doc"),
                    .init(
                        "pin/" + entry.id, entry.pinned ? "Unpin" : "Pin",
                        entry.pinned ? "pin.slash" : "pin"),
                ])
        }
        return .init(
            providerID: "colorPicker",
            metrics: [
                .init("total", "Clips", "\(colors.count)"),
                .init("pinned", "Pinned", "\(colors.filter(\.pinned).count)"),
            ], rows: rows, actions: [pickAction],
            message: colors.isEmpty ? emptyMessage : nil, updatedAt: Date())
    }

    private static func bounded(_ value: String) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= 768 else { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result
    }
}

enum ColorPickerClipboardPeer {
    struct Snapshot: Decodable {
        let entries: [ColorPickerClipboardEntry]
        let revision: String
        let total: Int
    }
    struct Page: Encodable {
        let offset: Int
        let limit = 200
        let revision: String?
        let recentlyCreated = false
    }
    struct CopyRequest: Encodable {
        let id: String
        let plainTextOnly = true
    }
    struct CopyPayload: Decodable {
        let data: Data
        let text: String?
    }
    struct Mutation: Encodable {
        let kind: String
        let ids: [String]
        let copiedAt = Date()
    }

    static var active: Bool {
        guard let text = ExtensionSharedState.current?.values(for: "host")["surface.activeIDs"],
            text.utf8.count <= 16_384,
            let ids = try? JSONDecoder().decode([String].self, from: Data(text.utf8)),
            ids.count <= 128
        else { return false }
        return ids.contains("clipboard")
    }

    static var pinToTop: Bool {
        (SharedDefaults.store.string(forKey: AppStorageKeys.Clipboard.pinTo) ?? "top") != "bottom"
    }

    static func invoke(_ command: String, payload: Data) async throws -> Data {
        guard active, let endpoint = ExtensionPeerEndpoint.current(owner: "clipboard") else {
            throw ExtensionPeerError.unavailable
        }
        return try await endpoint.invoke(command, payload: payload, timeout: 20)
    }

    static func entries() async throws -> [ColorPickerClipboardEntry] {
        var result: [ColorPickerClipboardEntry] = []
        var revision: String?
        while true {
            try Task.checkCancellation()
            let response = try await invoke(
                "clipboard.snapshot",
                payload: JSONEncoder().encode(Page(offset: result.count, revision: revision)))
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: response)
            guard snapshot.total >= 0, snapshot.total <= 100_000, snapshot.entries.count <= 256,
                revision == nil || revision == snapshot.revision
            else { throw ExtensionPeerError.invalidRequest }
            result += snapshot.entries
            revision = snapshot.revision
            if result.count >= snapshot.total || snapshot.entries.isEmpty { return result }
        }
    }

    @MainActor static func perform(_ actionID: String) async throws {
        let parts = actionID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[1]) != nil else {
            throw ExtensionPeerError.invalidRequest
        }
        switch parts[0] {
        case "copy":
            let response = try await invoke(
                "clipboard.copyPayload", payload: JSONEncoder().encode(CopyRequest(id: parts[1])))
            let payload = try JSONDecoder().decode(CopyPayload.self, from: response)
            try Task.checkCancellation()
            guard let text = payload.text ?? String(data: payload.data, encoding: .utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            _ = try await invoke(
                "clipboard.mutate",
                payload: JSONEncoder().encode(Mutation(kind: "copied", ids: [parts[1]])))
        case "pin":
            guard let entry = try await entries().first(where: { $0.id == parts[1] }) else {
                throw ExtensionPeerError.invalidRequest
            }
            _ = try await invoke(
                "clipboard.mutate",
                payload: JSONEncoder().encode(
                    Mutation(kind: entry.pinned ? "unpin" : "pin", ids: [entry.id])))
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
