import EdithExtensionSupport
import EdithHostCore
import Foundation
import Network

final class CompanionFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "edith.companion.fixture")
    private let lock = NSLock()
    private var recorded: [String] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var requests: [String] { lock.withLock { recorded } }

    func start() async throws {
        let listener = listener
        let started = CompanionFixtureOnce()
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, started.claim() else { return }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard started.claim() else { return }
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] bytes, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let bytes { buffer.append(bytes) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ").map(String.init)
            let target = parts.count >= 2 ? parts[1] : ""
            let path = String(target.split(separator: "?").first ?? "")
            self.lock.withLock { self.recorded.append((parts.first ?? "") + " " + path) }
            let (status, body) = Self.response(path)
            var response = Data(
                ("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
                    + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
                    + "Connection: close\r\n\r\n").utf8)
            response.append(body)
            connection.send(
                content: response,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    static let episodes = [
        ("ep-note", "note", "Synthetic note", "2026-10-09T10:00:00Z"),
        ("ep-voice", "voice", "Synthetic voice memo", "2026-10-09T11:00:00Z"),
        ("ep-pdf", "pdf", "Synthetic document", "2026-10-09T09:00:00Z"),
    ]

    private static func response(_ path: String) -> (Int, Data) {
        let object: Any
        switch path {
        case "/v1/health":
            object = [
                "ok": true, "degraded": false,
                "checks": [
                    ["name": "postgres", "ok": true, "detail": "synthetic ready"],
                    ["name": "embeddings", "ok": true, "detail": "synthetic model"],
                ],
            ]
        case "/v1/status":
            object = [
                "sources": 2, "episodes": 3, "claims": 4, "observations": 5, "chunks": 6,
                "pending_episodes": 1,
            ]
        case "/v1/episodes":
            object = episodes.map {
                ["id": $0.0, "kind": $0.1, "title": $0.2, "occurred_at": $0.3, "sha256": "00"]
            }
        case "/v1/search":
            object = [
                [
                    "chunkId": "chunk-1", "episodeId": "ep-note", "ord": 0,
                    "title": "Synthetic note", "occurredAt": "2026-10-09T10:00:00Z",
                    "kind": "note", "snippet": "synthetic memory snippet", "score": 0.9,
                ]
            ]
        default:
            return (404, Data("{\"error\":\"not found\"}".utf8))
        }
        return (200, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}

private final class CompanionFixtureOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

enum CompanionFixtureError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}

@MainActor
func verifyCompanion(
    _ endpoint: ExtensionPeerEndpoint, server: CompanionFixtureServer
) async throws {
    func object(_ command: String, _ input: [String: Any] = [:]) async throws -> Any {
        try JSONSerialization.jsonObject(
            with: try await endpoint.invoke(
                command, payload: JSONSerialization.data(withJSONObject: input)))
    }
    let status = try await object("companion.status") as? [String: Any]
    guard status?["configured"] as? Bool == true, status?["monitoring"] as? Bool == true,
        status?["endpoint"] as? String == "http://127.0.0.1:\(server.port)",
        status?["deployed"] as? Bool == false, status?["outboxWaiting"] as? Int == 0
    else {
        throw CompanionFixtureError.failed("Companion status was \(String(describing: status)).")
    }
    let health = try await object("companion.health", ["refresh": true]) as? [String: Any]
    guard health?["reachable"] as? Bool == true, health?["skipped"] as? Bool == false,
        (health?["checks"] as? [[String: Any]])?.compactMap({ $0["name"] as? String })
            == ["postgres", "embeddings"]
    else {
        throw CompanionFixtureError.failed("Companion health was \(String(describing: health)).")
    }
    let hits =
        try await object("companion.search", ["query": "synthetic", "limit": 5])
        as? [[String: Any]]
    guard hits?.count == 1, hits?.first?["episodeId"] as? String == "ep-note" else {
        throw CompanionFixtureError.failed("Companion search returned \(String(describing: hits)).")
    }
    do {
        _ = try await object("companion.search", ["query": "   "])
        throw CompanionFixtureError.failed("An empty Companion search was accepted.")
    } catch is ExtensionPeerError {}
    do {
        _ = try await endpoint.invoke("companion.unknown")
        throw CompanionFixtureError.failed("An unknown Companion command was accepted.")
    } catch is ExtensionPeerError {}

    var tile = SurfaceTile(.ability("companion"))
    tile.itemLimit = 10
    let full = try SurfaceSnapshot.decode(
        try await endpoint.invoke(
            "surface.snapshot",
            payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                providerID: "companion")), providerID: "companion")
    let metrics = Dictionary(uniqueKeysWithValues: full.metrics.map { ($0.id, $0.value) })
    guard metrics["status"] == "Healthy", metrics["episodes"] == "3", metrics["pending"] == "1",
        Set(full.sources.map(\.id)) == ["note", "voice", "pdf"],
        full.rows.contains(where: {
            $0.id == "episode:ep-voice" && $0.actions.map(\.id) == ["episode/ep-voice"]
        }),
        full.rows.contains(where: { $0.id == "health:postgres" && $0.sourceID == "health" }),
        full.actions.map(\.id) == ["open", "refresh"]
    else { throw CompanionFixtureError.failed("Companion surface was \(full).") }

    var recent = SurfaceTile(.ability("companion"))
    recent.contentKinds = ["recent"]
    recent.sourceIDs = ["voice"]
    recent.hiddenFields = ["episodes"]
    let filtered = try SurfaceSnapshot.decode(
        try await endpoint.invoke(
            "surface.snapshot",
            payload: SurfaceSnapshotRequest(target: .notch, tile: recent).encoded(
                providerID: "companion")), providerID: "companion")
    guard filtered.rows.map(\.id) == ["episode:ep-voice"], filtered.metrics.isEmpty else {
        throw CompanionFixtureError.failed("Companion source filtering returned \(filtered).")
    }

    let before = server.requests.filter { $0 == "GET /v1/health" }.count
    let refreshed = try SurfaceSnapshot.decode(
        try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: .init(target: .home, tile: tile), actionID: "refresh"
            ).encoded(providerID: "companion")), providerID: "companion")
    guard server.requests.filter({ $0 == "GET /v1/health" }).count > before,
        refreshed.metrics.first?.value == "Healthy"
    else { throw CompanionFixtureError.failed("The Companion refresh action did not probe.") }

    var hidden = tile
    hidden.showActions = false
    do {
        _ = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: .init(target: .home, tile: hidden), actionID: "refresh"
            ).encoded(providerID: "companion"))
        throw CompanionFixtureError.failed("A hidden Companion action was accepted.")
    } catch is ExtensionPeerError {}
    do {
        _ = try await endpoint.invoke(
            "surface.perform",
            payload: SurfaceActionRequest(
                snapshot: .init(target: .home, tile: tile), actionID: "episode/ep-missing"
            ).encoded(providerID: "companion"))
        throw CompanionFixtureError.failed("A stale Companion episode action was accepted.")
    } catch is ExtensionPeerError {}
}
