import Foundation

public struct CompanionConversation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let lastActiveAt: String
    public let messageCount: Int
    public let lastMessage: String?

    public init(
        id: String, title: String, createdAt: String, lastActiveAt: String,
        messageCount: Int, lastMessage: String?
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.messageCount = messageCount
        self.lastMessage = lastMessage
    }
}

public struct CompanionMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let content: String
    public let citations: [CompanionAskCitation]?
    public let model: String?
    public let latencyMs: Int?
    public let createdAt: String

    public init(
        id: String, role: String, content: String, citations: [CompanionAskCitation]?,
        model: String?, latencyMs: Int?, createdAt: String
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
        self.model = model
        self.latencyMs = latencyMs
        self.createdAt = createdAt
    }
}

public struct CompanionConversationDetail: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let messages: [CompanionMessage]

    public init(id: String, title: String, createdAt: String, messages: [CompanionMessage]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.messages = messages
    }
}

public struct CompanionEpisodeDetail: Codable, Equatable, Sendable {
    public let id: String
    public let occurredAt: String
    public let ingestedAt: String
    public let kind: String
    public let title: String
    public let body: String?
    public let bodyEn: String?
    public let langs: [String]
    public let durationS: Double?
    public let mediaRef: String?
    public let sha256: String
    public let bytes: Int
    public let chunks: Int

    public init(
        id: String, occurredAt: String, ingestedAt: String, kind: String, title: String,
        body: String?, bodyEn: String?, langs: [String], durationS: Double?, mediaRef: String?,
        sha256: String, bytes: Int, chunks: Int
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.ingestedAt = ingestedAt
        self.kind = kind
        self.title = title
        self.body = body
        self.bodyEn = bodyEn
        self.langs = langs
        self.durationS = durationS
        self.mediaRef = mediaRef
        self.sha256 = sha256
        self.bytes = bytes
        self.chunks = chunks
    }
}

public struct CompanionSignal: Codable, Equatable, Sendable {
    public let tStartS: Double
    public let tEndS: Double
    public let kind: String
    public let value: Double

    public init(tStartS: Double, tEndS: Double, kind: String, value: Double) {
        self.tStartS = tStartS
        self.tEndS = tEndS
        self.kind = kind
        self.value = value
    }
}

public struct CompanionReasonSettings: Codable, Equatable, Sendable {
    public let provider: String
    public let url: String
    public let model: String
    public let hasApiKey: Bool
    public let apiKeyHint: String
    public let configured: Bool
    public let description: String

    public init(
        provider: String, url: String, model: String, hasApiKey: Bool, apiKeyHint: String,
        configured: Bool, description: String
    ) {
        self.provider = provider
        self.url = url
        self.model = model
        self.hasApiKey = hasApiKey
        self.apiKeyHint = apiKeyHint
        self.configured = configured
        self.description = description
    }
}

public struct CompanionReasonTest: Codable, Equatable, Sendable {
    public let ok: Bool
    public let model: String
    public let latencyMs: Int

    public init(ok: Bool, model: String, latencyMs: Int) {
        self.ok = ok
        self.model = model
        self.latencyMs = latencyMs
    }
}

public struct CompanionNightlyStart: Codable, Equatable, Sendable {
    public let runId: String

    public init(runId: String) {
        self.runId = runId
    }
}

public struct CompanionDeletion: Codable, Equatable, Sendable {
    public let deleted: String

    public init(deleted: String) {
        self.deleted = deleted
    }
}

public enum CompanionMedia {
    public static func fileExtension(forContentType type: String) -> String {
        if type.contains("markdown") { return "md" }
        if type.contains("pdf") { return "pdf" }
        if type.contains("audio/wav") { return "wav" }
        if type.contains("audio/mp4") { return "m4a" }
        if type.contains("audio/mpeg") { return "mp3" }
        if type.contains("audio/ogg") { return "ogg" }
        if type.contains("audio/flac") { return "flac" }
        if type.contains("audio/aiff") { return "aiff" }
        return "bin"
    }

    public static func temporaryFile(title: String, contentType: String, data: Data) throws -> URL {
        let safe =
            title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-episodes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = safe.isEmpty ? "episode" : safe
        let url = directory.appendingPathComponent(
            "\(name).\(fileExtension(forContentType: contentType))")
        try data.write(to: url)
        return url
    }
}

public enum CompanionChatEvent: Equatable, Sendable {
    case meta(conversationId: String, model: String)
    case delta(String)
    case citations([CompanionAskCitation])
    case done(messageId: String, latencyMs: Int, chunksConsidered: Int)
    case failure(String)
}

extension CompanionClient {
    public func conversations(limit: Int) async throws -> [CompanionConversation] {
        try await getWithLimit("conversations", limit: limit)
    }

    public func conversation(id: String) async throws -> CompanionConversationDetail {
        try await get("conversations/\(id)")
    }

    public func deleteConversation(id: String) async throws -> CompanionDeletion {
        var request = URLRequest(url: url(for: "conversations/\(id)"))
        request.httpMethod = "DELETE"
        return try await self.request(request)
    }

    public func episodeDetail(id: String) async throws -> CompanionEpisodeDetail {
        try await get("episodes/\(id)")
    }

    public func signals(episodeId: String) async throws -> [CompanionSignal] {
        var components = URLComponents(url: url(for: "signals"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "episode", value: episodeId)]
        return try await request(URLRequest(url: components?.url ?? url(for: "signals")))
    }

    public func media(episodeId: String) async throws -> (Data, String) {
        var request = URLRequest(url: url(for: "episodes/\(episodeId)/media"))
        request.timeoutInterval = 120
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CompanionClientError.unreachable("the server returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionClientError.badResponse(
                http.statusCode,
                String(decoding: data, as: UTF8.self))
        }
        return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    public func reasonSettings() async throws -> CompanionReasonSettings {
        try await get("settings/reason")
    }

    public func updateReasonSettings(
        provider: String?, url updatedURL: String?, model: String?, apiKey: String?
    ) async throws -> CompanionReasonSettings {
        var request = URLRequest(url: url(for: "settings/reason"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(
                ReasonSettingsRequest(
                    provider: provider, url: updatedURL, model: model, apiKey: apiKey))
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        return try await self.request(request)
    }

    public func testReason() async throws -> CompanionReasonTest {
        var request = URLRequest(url: url(for: "settings/reason/test"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: CompanionClient.longRequestTimeout)
    }

    public func nightlyRun() async throws -> CompanionNightlyStart {
        var request = URLRequest(url: url(for: "nightly/run"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: 1800)
    }

    public func chat(message: String, conversationId: String?, persona: String? = nil)
        -> AsyncThrowingStream<
            CompanionChatEvent, Error
        >
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url(for: "chat"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 600
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(
                            message: message, conversationId: conversationId, persona: persona))
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw CompanionClientError.unreachable(
                            "the server returned no HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                        }
                        throw CompanionClientError.badResponse(http.statusCode, body)
                    }
                    var eventName = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6)).trimmingCharacters(
                                in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst(5)).trimmingCharacters(
                                in: .whitespaces)
                            if let event = Self.decodeChatEvent(name: eventName, payload: payload) {
                                continuation.yield(event)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decodeChatEvent(name: String, payload: String) -> CompanionChatEvent? {
        let data = Data(payload.utf8)
        let decoder = JSONDecoder()
        switch name {
        case "meta":
            guard let meta = try? decoder.decode(ChatMeta.self, from: data) else { return nil }
            return .meta(conversationId: meta.conversationId, model: meta.model)
        case "delta":
            guard let delta = try? decoder.decode(ChatDelta.self, from: data) else { return nil }
            return .delta(delta.text)
        case "citations":
            guard let citations = try? decoder.decode([CompanionAskCitation].self, from: data)
            else { return nil }
            return .citations(citations)
        case "done":
            guard let done = try? decoder.decode(ChatDone.self, from: data) else { return nil }
            return .done(
                messageId: done.messageId, latencyMs: done.latencyMs,
                chunksConsidered: done.chunksConsidered)
        case "error":
            guard let failure = try? decoder.decode(ChatFailure.self, from: data) else {
                return nil
            }
            return .failure(failure.error)
        default:
            return nil
        }
    }

    private func getWithLimit<T: Decodable>(_ path: String, limit: Int) async throws -> T {
        var components = URLComponents(url: url(for: path), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return try await request(URLRequest(url: components?.url ?? url(for: path)))
    }
}

private struct ChatRequest: Encodable {
    let message: String
    let conversationId: String?
    let persona: String?
}

private struct ReasonSettingsRequest: Encodable {
    let provider: String?
    let url: String?
    let model: String?
    let apiKey: String?
}

private struct ChatMeta: Decodable {
    let conversationId: String
    let model: String
}

private struct ChatDelta: Decodable {
    let text: String
}

private struct ChatDone: Decodable {
    let messageId: String
    let latencyMs: Int
    let chunksConsidered: Int
}

private struct ChatFailure: Decodable {
    let error: String
}
