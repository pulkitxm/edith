import AppKit
import EdithExtensionSupport
import Foundation

public struct BifrostClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public let types: [String]
    public let ext: String
    public let sourceApp: String?
    public let sourceBundleID: String?
    public let createdAt: Date
    public var lastCopiedAt: Date
    public let size: Int
    public let preview: String?
    public var pinned: Bool
}

public enum BifrostPeers {
    public static var activeIDs: Set<String> {
        guard let text = ExtensionSharedState.current?.values(for: "host")["surface.activeIDs"],
            text.utf8.count <= 16_384,
            let ids = try? JSONDecoder().decode([String].self, from: Data(text.utf8)),
            ids.count <= 128
        else { return [] }
        return Set(ids)
    }

    public static func invoke(owner: String, command: String, payload: Data = Data()) async throws
        -> Data
    {
        guard activeIDs.contains(owner), let endpoint = ExtensionPeerEndpoint.current(owner: owner)
        else { throw ExtensionPeerError.unavailable }
        return try await endpoint.invoke(command, payload: payload, timeout: 20)
    }

    public static func clipboardEntries() async throws -> [BifrostClipboardEntry] {
        struct Snapshot: Decodable {
            let entries: [BifrostClipboardEntry]; let revision: String; let total: Int
        }
        struct Request: Encodable {
            let offset: Int; let limit = 256; let revision: String?; let recentlyCreated = false
        }
        let privacy = ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        let hidden = await MainActor.run {
            SurfacePrivacyState.hides(
                SurfaceWidget(rawValue: "extension:clipboard")!, values: privacy)
        }
        guard !hidden else { return [] }
        var result: [BifrostClipboardEntry] = []
        var revision: String?
        while true {
            try Task.checkCancellation()
            let payload = try JSONEncoder().encode(
                Request(offset: result.count, revision: revision))
            let response = try await invoke(
                owner: "clipboard", command: "clipboard.snapshot", payload: payload)
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: response)
            guard snapshot.total >= 0, snapshot.total <= 100_000, snapshot.entries.count <= 256,
                revision == nil || revision == snapshot.revision
            else { throw ExtensionPeerError.invalidRequest }
            result += snapshot.entries
            guard result.count <= snapshot.total else { throw ExtensionPeerError.invalidRequest }
            revision = snapshot.revision
            if result.count == snapshot.total { return result }
            guard !snapshot.entries.isEmpty else { throw ExtensionPeerError.invalidRequest }
        }
    }

    @MainActor public static func copyClipboard(id: String) async throws {
        struct Request: Encodable { let id: String; let plainTextOnly = false }
        struct Payload: Decodable {
            let entry: BifrostClipboardEntry; let data: Data; let text: String?; let urls: [URL]?
        }
        let privacy = ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        guard
            !SurfacePrivacyState.hides(
                SurfaceWidget(rawValue: "extension:clipboard")!, values: privacy)
        else { throw ExtensionPeerError.unavailable }
        let data = try await invoke(
            owner: "clipboard", command: "clipboard.copyPayload",
            payload: JSONEncoder().encode(Request(id: id)))
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try Task.checkCancellation()
        guard payload.entry.id == id, activeIDs.contains("clipboard"),
            payload.data.count <= ExtensionPeerEndpoint.maximumPayloadBytes
        else { throw ExtensionPeerError.invalidRequest }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let urls = payload.urls, !urls.isEmpty {
            pasteboard.writeObjects(urls as [NSURL])
        } else {
            for type in payload.entry.types.prefix(32) {
                pasteboard.setData(payload.data, forType: .init(type))
            }
            if let text = payload.text { pasteboard.setString(text, forType: .string) }
        }
    }

    @MainActor public static func open(owner: String) async throws {
        _ = try await invoke(owner: owner, command: "extension.open")
    }
}
