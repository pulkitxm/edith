import Foundation
import Network

public final class AttentionIngestionServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    private let repository: AttentionRepository
    private let settings: AttentionSettings
    private let queue = DispatchQueue(label: "com.pulkit.edith.attention.server")
    private var listener: NWListener?
    private let stateLock = NSLock()
    private var storedState: State = .stopped
    private var storedPort: UInt16?

    public init(
        repository: AttentionRepository = AttentionRepository(), settings: AttentionSettings
    ) {
        self.repository = repository
        self.settings = settings
    }

    public var state: State {
        stateLock.withLock { storedState }
    }

    public var boundPort: UInt16? {
        stateLock.withLock { storedPort }
    }

    public func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: settings.serverPort) else {
            throw AttentionIngestionError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        setState(.starting)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setPort(listener.port?.rawValue)
                self?.setState(.ready)
            case let .failed(error): self?.setState(.failed(error.localizedDescription))
            case .cancelled: self?.setState(.stopped)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        setPort(nil)
        setState(.stopped)
    }

    public static func healthURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/health")!
    }

    public static func isHealthy(port: UInt16, timeout: TimeInterval = 2) async -> Bool {
        var request = URLRequest(url: healthURL(port: port))
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func setState(_ value: State) {
        stateLock.withLock { storedState = value }
    }

    private func setPort(_ value: UInt16?) {
        stateLock.withLock { storedPort = value }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in connection?.cancel() }
        receive(connection, data: Data())
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self] content, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = data
            if let content { accumulated.append(content) }
            guard accumulated.count <= 1_048_576 else {
                send(.init(status: 400, body: ["error": "request too large"]), over: connection)
                return
            }
            if let request = AttentionHTTPRequest.parse(accumulated) {
                send(response(for: request), over: connection)
                return
            }
            if complete || error != nil || accumulated.count >= 1_048_576 {
                send(.init(status: 400, body: ["error": "invalid request"]), over: connection)
                return
            }
            receive(connection, data: accumulated)
        }
    }

    private func response(for request: AttentionHTTPRequest) -> AttentionHTTPResponse {
        if request.method == "OPTIONS" {
            return .init(status: 204, body: [:])
        }
        if request.method == "GET", request.path == "/v1/health" {
            return .init(status: 200, body: ["status": "ok"])
        }
        guard request.method == "POST", request.path == "/v1/heartbeat" else {
            if request.method == "POST", request.path == "/v1/history" {
                return historyResponse(for: request)
            }
            return .init(status: 404, body: ["error": "not found"])
        }
        guard request.headers["x-edith-token"] == settings.serverToken else {
            return .init(status: 401, body: ["error": "unauthorized"])
        }
        do {
            let heartbeat = try Self.decoder.decode(
                AttentionBrowserHeartbeat.self, from: request.body)
            try ingest(heartbeat)
            return .init(status: 202, body: ["status": "accepted"])
        } catch {
            return .init(status: 422, body: ["error": "invalid heartbeat"])
        }
    }

    private func historyResponse(for request: AttentionHTTPRequest) -> AttentionHTTPResponse {
        guard request.headers["x-edith-token"] == settings.serverToken else {
            return .init(status: 401, body: ["error": "unauthorized"])
        }
        do {
            let payload = try Self.decoder.decode(AttentionHistoryImport.self, from: request.body)
            let visits = payload.visits.compactMap { sanitize(visit: $0) }
            try repository.importHistory(visits)
            return .init(
                status: 202,
                body: ["status": "accepted", "imported": String(visits.count)])
        } catch {
            return .init(status: 422, body: ["error": "invalid history"])
        }
    }

    private func sanitize(visit: AttentionHistoryVisit) -> AttentionHistoryVisit? {
        guard var components = URLComponents(string: visit.url),
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        components.query = nil
        components.fragment = nil
        let storedURL: String
        switch settings.privacyLevel {
        case .applications: return nil
        case .domains: storedURL = host
        case .detailed: storedURL = components.string ?? host
        }
        return AttentionHistoryVisit(
            url: storedURL,
            title: settings.privacyLevel == .detailed
                ? visit.title.map { String($0.prefix(500)) } : nil,
            lastVisitedAt: visit.lastVisitedAt, visitCount: max(0, visit.visitCount),
            typedCount: max(0, visit.typedCount), profile: String(visit.profile.prefix(100)))
    }

    private func ingest(_ heartbeat: AttentionBrowserHeartbeat) throws {
        let event = Self.browserEvent(from: heartbeat, privacyLevel: settings.privacyLevel)
        try repository.append(event)
        for media in heartbeat.media where media.playing {
            try repository.append(
                AttentionEvent(
                    startedAt: event.startedAt, duration: event.duration, source: .media,
                    presence: heartbeat.presence, appName: heartbeat.appName,
                    bundleID: heartbeat.bundleID, domain: event.domain,
                    browserProfile: heartbeat.browserProfile, media: media))
        }
    }

    public static func browserEvent(
        from heartbeat: AttentionBrowserHeartbeat, privacyLevel: AttentionPrivacyLevel
    ) -> AttentionEvent {
        let components = heartbeat.url.flatMap(URLComponents.init(string:))
        let domain = (heartbeat.domain ?? components?.host)?.lowercased()
        var sanitizedURL: String?
        if privacyLevel == .detailed, var components {
            components.query = nil
            components.fragment = nil
            sanitizedURL = components.string
        }
        return AttentionEvent(
            startedAt: heartbeat.timestamp, duration: max(0, min(heartbeat.duration, 120)),
            source: .browser, presence: heartbeat.presence, appName: heartbeat.appName,
            bundleID: heartbeat.bundleID,
            windowTitle: privacyLevel == .detailed
                ? heartbeat.title.map { String($0.prefix(500)) } : nil,
            url: sanitizedURL, domain: privacyLevel == .applications ? nil : domain,
            faviconURL: privacyLevel == .applications ? nil : heartbeat.faviconURL,
            browserProfile: heartbeat.browserProfile)
    }

    private func send(_ response: AttentionHTTPResponse, over connection: NWConnection) {
        connection.send(
            content: response.data,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct AttentionHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public static func parse(_ data: Data) -> AttentionHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
            let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestParts = first.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let bodyStart = headerRange.upperBound
        guard data.count <= 1_048_576,
            let length = Int(headers["content-length"] ?? "0"), length >= 0,
            length <= 1_048_576 - bodyStart
        else { return nil }
        guard data.count >= bodyStart + length else { return nil }
        return AttentionHTTPRequest(
            method: String(requestParts[0]), path: String(requestParts[1]), headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

public struct AttentionHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: [String: String]

    public init(status: Int, body: [String: String]) {
        self.status = status
        self.body = body
    }

    public var data: Data {
        let reason =
            switch status {
            case 200: "OK"
            case 202: "Accepted"
            case 204: "No Content"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 404: "Not Found"
            case 422: "Unprocessable Content"
            default: "Error"
            }
        let payload =
            (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json",
            "Content-Length: \(payload.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Headers: Content-Type, X-Edith-Token",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(headers.utf8) + payload
    }
}

public enum AttentionIngestionError: LocalizedError {
    case invalidPort

    public var errorDescription: String? { "The browser ingestion port is invalid." }
}
