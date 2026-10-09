import Foundation

public enum SurfaceMemoryReadError: LocalizedError {
    case invalidEndpoint, responseTooLarge, badResponse(Int), unreadable
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The configured Memory endpoint needs HTTP or HTTPS."
        case .responseTooLarge: "Memory returned more metadata than this widget can display."
        case .badResponse(let code): "Memory metadata is unavailable, response \(code)."
        case .unreadable: "Memory returned unreadable metadata."
        }
    }
}

public struct SurfaceMemoryClient: Sendable {
    public static let maximumBytes = 1_048_576
    public static let recentLimit = 60
    public typealias Read = @Sendable (URLRequest) async throws -> Data
    private let endpoint: URL
    private let read: Read
    public init(endpoint: URL, read: @escaping Read = { try await Self.networkRead($0) }) {
        self.endpoint = endpoint; self.read = read
    }
    public func snapshot(_ health: CompanionHealthSnapshot, tile: SurfaceTile) async throws
        -> SurfaceExtensionSnapshot
    {
        let totals = tile.contentKinds?.contains("totals") ?? true
        let recent = tile.contentKinds?.contains("recent") ?? true
        guard !health.skipped, health.reachable, totals || recent else {
            return SurfaceMemoryProjection.snapshot(health, status: nil, episodes: [], tile: tile)
        }
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
            endpoint.host != nil, endpoint.fragment == nil, endpoint.query == nil
        else { throw SurfaceMemoryReadError.invalidEndpoint }
        async let status: (CompanionStatus?, String?) = load("status", enabled: totals)
        async let episodes: ([CompanionEpisode]?, String?) = load("episodes", enabled: recent)
        let (statusResult, episodeResult) = try await (status, episodes)
        let items = episodeResult.0 ?? []
        guard items.count <= 1000 else { throw SurfaceMemoryReadError.responseTooLarge }
        var value = SurfaceMemoryProjection.snapshot(
            health, status: statusResult.0, episodes: items, tile: tile)
        let errors = Set([statusResult.1, episodeResult.1].compactMap { $0 }).sorted()
        if !errors.isEmpty {
            value.message = ([value.message].compactMap { $0 } + errors).joined(separator: " ")
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
        guard let url = components?.url else { throw SurfaceMemoryReadError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let data = try await read(request)
            guard data.count <= Self.maximumBytes else {
                throw SurfaceMemoryReadError.responseTooLarge
            }
            guard let value = try? JSONDecoder().decode(T.self, from: data) else {
                throw SurfaceMemoryReadError.unreadable
            }
            return (value, nil)
        } catch is CancellationError { throw CancellationError() } catch {
            try Task.checkCancellation()
            return (nil, String(error.localizedDescription.prefix(512)))
        }
    }
    public static func networkRead(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SurfaceMemoryReadError.unreadable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SurfaceMemoryReadError.badResponse(http.statusCode)
        }
        guard response.expectedContentLength <= maximumBytes else {
            throw SurfaceMemoryReadError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            if data.count >= maximumBytes { throw SurfaceMemoryReadError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

public enum SurfaceMemoryProjection {
    public static func snapshot(
        _ health: CompanionHealthSnapshot, status: CompanionStatus?, episodes: [CompanionEpisode],
        tile: SurfaceTile
    ) -> SurfaceExtensionSnapshot {
        let kinds = tile.contentKinds
        var value = SurfaceExtensionSnapshot(updatedAt: health.checkedAt)
        if kinds?.contains("health") ?? true {
            value.metrics = [
                .init(
                    "status", "Memory service",
                    health.skipped
                        ? "Not set up"
                        : !health.reachable ? "Offline" : health.degraded ? "Degraded" : "Healthy")
            ]
            value.rows = health.checks.sorted { !$0.ok && $1.ok }.map {
                .init(
                    "health:" + $0.name, source: "health", title: $0.name, detail: $0.detail,
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
            let precise = ISO8601DateFormatter();
            precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            func date(_ item: CompanionEpisode) -> Date? {
                precise.date(from: item.occurredAt) ?? plain.date(from: item.occurredAt)
            }
            var seen = Set<String>()
            let items = episodes.sorted { (date($0) ?? .distantPast) > (date($1) ?? .distantPast) }
                .filter {
                    !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.kind.utf8.count <= 128
                        && seen.insert($0.id).inserted
                }
                .prefix(SurfaceMemoryClient.recentLimit)
            let available = Set(items.map(\.kind)).union(tile.sourceIDs ?? [])
            value.sources = available.sorted().map { .init($0, kindTitle($0)) }
            value.rows += items.filter { tile.sourceIDs?.contains($0.kind) ?? true }.map {
                .init(
                    "episode:" + $0.id, source: $0.kind,
                    title: $0.title.isEmpty ? "Untitled item" : $0.title,
                    detail: date($0).map { $0.formatted(.dateTime.month().day().hour().minute()) }
                        ?? "Date unavailable",
                    value: kindTitle($0.kind),
                    icon: $0.kind == "voice"
                        ? "waveform" : $0.kind == "pdf" ? "doc.richtext" : "doc.text",
                    actions: [.init("Open Memory", "arrow.up.right", .navigate("companion"))])
            }
            if !episodes.isEmpty {
                value.message =
                    "Recent items include up to 60 entries. Totals describe the whole Memory service."
            }
        }
        if health.skipped {
            value.message = "Open Memory to set up its service."
        } else if !health.reachable {
            value.message =
                health.failure ?? "Memory is unavailable. Open it to review the connection."
        }
        value.actions = [.init("Open Memory", "arrow.up.right", .navigate("companion"))]
        return value
    }
    private static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "voice": "Voice memo"
        case "pdf": "Document"
        case "note": "Note"
        case "text": "Text"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
