import CryptoKit
import EdithExtensionSupport
import Foundation

@MainActor final class BifrostSurface {
    private let store: BifrostStore
    private let open: @MainActor (String) -> Void
    private let privacy: @MainActor () -> [String: String]
    init(
        store: BifrostStore,
        open: @escaping @MainActor (String) -> Void = { BifrostPanel.shared.show(query: $0) },
        privacy: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) { self.store = store; self.open = open; self.privacy = privacy }

    func execute(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("surface.") {
            return try await SurfaceCommandService.execute(
                providerID: "bifrost", command: command, payload: payload, snapshot: snapshot,
                perform: perform, privacyValues: privacy)
        }
        guard !SurfacePrivacyState.hides(.ability("bifrost"), values: privacy()) else {
            throw ExtensionPeerError.unavailable
        }
        struct Query: Decodable { let query: String }
        struct Value: Encodable { let value: String }
        switch command {
        case "bifrost.open":
            let query =
                payload.isEmpty ? "" : try JSONDecoder().decode(Query.self, from: payload).query
            guard query.utf8.count <= 1_024, !query.utf8.contains(0) else {
                throw ExtensionPeerError.invalidRequest
            }
            open(query); return Data("{\"opened\":true}".utf8)
        case "bifrost.ls":
            guard payload.isEmpty || payload == Data("{}".utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(store.applications)
        case "bifrost.calc", "bifrost.convert":
            let query = try JSONDecoder().decode(Query.self, from: payload).query
            guard query.utf8.count <= 1_024, !query.utf8.contains(0) else {
                throw ExtensionPeerError.invalidRequest
            }
            let value =
                command == "bifrost.calc"
                ? try BifrostOperationExecution.calculate(query).copyText
                : try BifrostOperationExecution.convert(query).copyText
            return try JSONEncoder().encode(Value(value: value))
        case "bifrost.reindex":
            guard payload.isEmpty || payload == Data("{}".utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
            store.reindex(); return Data("{\"requested\":true}".utf8)
        case "bifrost.clear":
            guard payload.isEmpty || payload == Data("{}".utf8) else {
                throw ExtensionPeerError.invalidRequest
            }
            let removed = BifrostOperationExecution.clear()
            return try JSONEncoder().encode(["removed": removed])
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        let field = tile.widget == .desk ? "bifrost" : nil
        guard field == nil || tile.shows("bifrost") else { return .init(providerID: "bifrost") }
        let rows = Array(store.applications.prefix(tile.itemLimit)).map { application in
            SurfaceDataRow(
                Self.actionID(application), sourceID: "applications",
                title: String(application.name.prefix(120)),
                detail: application.bundleID ?? "Application", icon: "app", field: field,
                actions: [.init(Self.actionID(application), "Open", "arrow.up.right", field: field)]
            )
        }
        return .init(
            providerID: "bifrost",
            metrics: [
                .init("applications", "Applications", "\(store.applications.count)"),
                .init("sources", "Sources", "\(BifrostSource.enabled().count)"),
            ], rows: rows,
            actions: [
                .init("open", "Open Bifrost", "command", field: field),
                .init("reindex", "Rebuild index", "arrow.clockwise", field: field),
            ], sources: [.init("applications", "Applications")],
            message: store.isIndexing ? "Updating application index" : nil,
            updatedAt: store.indexedAt)
    }

    private func perform(_ id: String) async throws {
        switch id {
        case "open": open("")
        case "reindex": store.reindex()
        default:
            guard let application = store.applications.first(where: { Self.actionID($0) == id }),
                !BifrostFixture.enabled,
                store.run(
                    .init(
                        id: id, kind: .application, title: application.name, subtitle: "",
                        symbolName: "app", action: .launch(path: application.path), score: 0))
            else { throw ExtensionPeerError.invalidRequest }
        }
    }

    private static func actionID(_ application: BifrostApplication) -> String {
        "launch/"
            + SHA256.hash(data: Data(application.path.utf8)).map { String(format: "%02x", $0) }
            .joined()
    }
}
