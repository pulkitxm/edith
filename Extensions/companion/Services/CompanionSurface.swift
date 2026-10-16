import EdithExtensionSupport
import Foundation

enum CompanionSurfaceReadError: LocalizedError {
    case invalidEndpoint, responseTooLarge, badResponse(Int), unreadable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The configured Memory endpoint needs HTTP or HTTPS."
        case .responseTooLarge: "Memory returned more metadata than this widget can display."
        case .badResponse(let code): "Memory metadata is unavailable, response \(code)."
        case .unreadable: "Memory returned unreadable metadata."
        }
    }
}

struct CompanionSurfaceReader: Sendable {
    static let maximumBytes = 1_048_576
    static let recentLimit = 60
    typealias Read = @Sendable (URLRequest) async throws -> Data

    private let endpoint: URL
    private let read: Read

    init(endpoint: URL, read: @escaping Read = { try await Self.networkRead($0) }) {
        self.endpoint = endpoint
        self.read = read
    }

    func snapshot(_ health: CompanionHealthSnapshot, tile: SurfaceTile) async throws
        -> SurfaceSnapshot
    {
        let totals = tile.contentKinds?.contains("totals") ?? true
        let recent = tile.contentKinds?.contains("recent") ?? true
        guard !health.skipped, health.reachable, totals || recent else {
            return CompanionSurfaceProjection.snapshot(
                health, status: nil, episodes: [], tile: tile)
        }
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
            endpoint.host != nil, endpoint.fragment == nil, endpoint.query == nil
        else { throw CompanionSurfaceReadError.invalidEndpoint }
        async let status: (CompanionStatus?, String?) = load("status", enabled: totals)
        async let episodes: ([CompanionEpisode]?, String?) = load("episodes", enabled: recent)
        let (statusResult, episodeResult) = try await (status, episodes)
        let items = episodeResult.0 ?? []
        guard items.count <= 1000 else { throw CompanionSurfaceReadError.responseTooLarge }
        var value = CompanionSurfaceProjection.snapshot(
            health, status: statusResult.0, episodes: items, tile: tile)
        let errors = Set([statusResult.1, episodeResult.1].compactMap { $0 }).sorted()
        if !errors.isEmpty {
            value.message = CompanionSurfaceProjection.bounded(
                ([value.message].compactMap { $0 } + errors).joined(separator: " "), bytes: 4096)
        }
        return value
    }

    private func load<T: Decodable & Sendable>(_ path: String, enabled: Bool) async throws -> (
        T?, String?
    ) {
        guard enabled else { return (nil, nil) }
        var components = URLComponents(
            url: endpoint.appendingPathComponent("v1").appendingPathComponent(path),
            resolvingAgainstBaseURL: false)
        if path == "episodes" {
            components?.queryItems = [.init(name: "limit", value: "\(Self.recentLimit)")]
        }
        guard let url = components?.url else { throw CompanionSurfaceReadError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let data = try await read(request)
            guard data.count <= Self.maximumBytes else {
                throw CompanionSurfaceReadError.responseTooLarge
            }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else {
                throw CompanionSurfaceReadError.unreadable
            }
            return (value, nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return (nil, String(error.localizedDescription.prefix(512)))
        }
    }

    static func networkRead(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await CompanionTransport.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CompanionSurfaceReadError.unreadable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionSurfaceReadError.badResponse(http.statusCode)
        }
        guard response.expectedContentLength <= maximumBytes else {
            throw CompanionSurfaceReadError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximumBytes { throw CompanionSurfaceReadError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

enum CompanionSurfaceProjection {
    static func snapshot(
        _ health: CompanionHealthSnapshot, status: CompanionStatus?, episodes: [CompanionEpisode],
        tile: SurfaceTile
    ) -> SurfaceSnapshot {
        let kinds = tile.contentKinds
        var value = SurfaceSnapshot(providerID: "companion", updatedAt: health.checkedAt)
        if kinds?.contains("health") ?? true {
            value.metrics = [
                .init(
                    "status", "Memory service",
                    health.skipped
                        ? "Not set up"
                        : !health.reachable ? "Offline" : health.degraded ? "Degraded" : "Healthy")
            ]
            var seen = Set<String>()
            value.rows = health.checks.sorted { !$0.ok && $1.ok }
                .filter { !$0.name.isEmpty && seen.insert($0.name).inserted }
                .prefix(20)
                .map {
                    SurfaceDataRow(
                        "health:" + bounded($0.name, bytes: 400), sourceID: "health",
                        title: bounded($0.name, bytes: 1024),
                        detail: bounded($0.detail, bytes: 4096),
                        value: $0.ok ? "Ready" : "Needs attention",
                        icon: $0.ok ? "checkmark.circle" : "exclamationmark.circle")
                }
        }
        if kinds?.contains("totals") ?? true, let status {
            value.metrics += [
                .init("episodes", "Indexed items", "\(max(0, status.episodes))"),
                .init("sources", "Sources", "\(max(0, status.sources))"),
                .init("claims", "Claims", "\(max(0, status.claims))"),
                .init("observations", "Observations", "\(max(0, status.observations))"),
                .init("pending", "Pending indexing", "\(max(0, status.pendingEpisodes))"),
            ]
        }
        if kinds?.contains("recent") ?? true {
            let precise = ISO8601DateFormatter()
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            func date(_ item: CompanionEpisode) -> Date? {
                precise.date(from: item.occurredAt) ?? plain.date(from: item.occurredAt)
            }
            var seen = Set<String>()
            let items = episodes.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
                .filter {
                    !$0.id.isEmpty && $0.id.utf8.count <= 256 && !$0.id.contains("/")
                        && !$0.kind.isEmpty && $0.kind.utf8.count <= 128
                        && seen.insert($0.id).inserted
                }
                .prefix(CompanionSurfaceReader.recentLimit)
            let available = Set(items.map(\.kind)).union(tile.sourceIDs ?? [])
            value.sources = available.sorted().prefix(100).map { .init($0, kindTitle($0)) }
            let remaining = max(0, 100 - value.rows.count)
            value.rows += items.filter { tile.sourceIDs?.contains($0.kind) ?? true }
                .prefix(remaining)
                .map {
                    SurfaceDataRow(
                        "episode:" + $0.id, sourceID: $0.kind,
                        title: $0.title.isEmpty ? "Untitled item" : bounded($0.title, bytes: 1024),
                        detail: date($0).map {
                            $0.formatted(.dateTime.month().day().hour().minute())
                        } ?? "Date unavailable",
                        value: bounded(kindTitle($0.kind), bytes: 256),
                        icon: $0.kind == "voice"
                            ? "waveform" : $0.kind == "pdf" ? "doc.richtext" : "doc.text",
                        actions: [.init("episode/" + $0.id, "Open in Memory", "arrow.up.right")])
                }
            if !episodes.isEmpty {
                value.message =
                    "Recent items include up to 60 entries. Totals describe the whole Memory service."
            }
        }
        if health.skipped {
            value.message = "Open Memory to set up its service."
        } else if !health.reachable {
            value.message = bounded(
                health.failure ?? "Memory is unavailable. Open it to review the connection.",
                bytes: 4096)
        }
        value.actions = [
            .init("open", "Open Memory", "arrow.up.right"),
            .init("refresh", "Check health", "arrow.clockwise"),
        ]
        return value
    }

    static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "voice": "Voice memo"
        case "pdf": "Document"
        case "note": "Note"
        case "text": "Text"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func bounded(_ value: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= bytes else { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result
    }
}

@MainActor
final class CompanionSurface {
    private let monitor: CompanionMonitor
    private let isStopped: @MainActor () -> Bool
    private let privacyValues: @MainActor () -> [String: String]
    private let endpoint: @MainActor () -> URL
    private let read: CompanionSurfaceReader.Read
    private let open: @MainActor (String?) -> Void

    init(
        monitor: CompanionMonitor, isStopped: @escaping @MainActor () -> Bool = { false },
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        },
        endpoint: @escaping @MainActor () -> URL = { CompanionClient.endpoint(override: nil) },
        read: @escaping CompanionSurfaceReader.Read = {
            try await CompanionSurfaceReader.networkRead($0)
        },
        open: @escaping @MainActor (String?) -> Void
    ) {
        self.monitor = monitor
        self.isStopped = isStopped
        self.privacyValues = privacyValues
        self.endpoint = endpoint
        self.read = read
        self.open = open
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "companion", command: command, payload: payload,
            snapshot: { try await self.snapshot($0) },
            perform: { try await self.perform($0) }, privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) async throws -> SurfaceSnapshot {
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        let health = await monitor.current()
        try Task.checkCancellation()
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        let snapshot = try await CompanionSurfaceReader(endpoint: endpoint(), read: read)
            .snapshot(health, tile: tile)
        try Task.checkCancellation()
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        return snapshot
    }

    private func perform(_ actionID: String) async throws {
        guard !isStopped() else { throw ExtensionPeerError.unavailable }
        switch actionID {
        case "open": open(nil)
        case "refresh": _ = await monitor.refresh()
        default:
            let parts = actionID.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "episode", !parts[1].isEmpty else {
                throw ExtensionPeerError.invalidRequest
            }
            open(parts[1])
        }
    }
}
