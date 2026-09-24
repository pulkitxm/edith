import Foundation

public struct JevClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!
    public static let baseURLOverrideKey = "EDITH_JEV_BASE_URL"

    public var apiKey: String
    public var baseURL: URL
    public var retries: Int
    private let session: URLSession

    public init(
        apiKey: String, baseURL: URL = JevClient.resolvedBaseURL(), retries: Int = 1,
        session: URLSession = JevClient.sharedSession
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.retries = retries
        self.session = session
    }

    public static func resolvedBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        environment[baseURLOverrideKey].flatMap(URL.init(string:)) ?? defaultBaseURL
    }

    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    public func decide(_ request: JevRequest) async throws -> JevDecision {
        let body = try JSONEncoder().encode(request.validated())
        var attempt = 0
        while true {
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let data = try await send(path: "v1/systemone", method: "POST", body: body)
                let elapsed = (clock.now - started).components
                guard let response = try? JSONDecoder().decode(JevResponse.self, from: data) else {
                    throw JevError.malformedResponse
                }
                let milliseconds = Int(
                    elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
                return JevDecision(response: response, milliseconds: milliseconds)
            } catch let error as JevError where error.isRetryable && attempt < retries {
                attempt += 1
                try await Task.sleep(for: backoff(error, attempt: attempt))
            }
        }
    }

    public func models() async throws -> [JevModelInfo] {
        struct Listing: Decodable { var models: [JevModelInfo] }
        let data = try await send(path: "v1/models", method: "GET", body: nil)
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw JevError.malformedResponse
        }
        return listing.models
    }

    private func send(path: String, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JevError.unavailable(
                "TypeSafe could not be reached: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        if let error = Self.error(
            status: http?.statusCode ?? 0, data: data,
            retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        {
            throw error
        }
        return data
    }

    private func backoff(_ error: JevError, attempt: Int) -> Duration {
        if case .rateLimited(let after?) = error {
            return .milliseconds(Int(min(after, 5) * 1000))
        }
        return .milliseconds(150 * (1 << attempt))
    }

    public static func error(status: Int, data: Data, retryAfter: TimeInterval? = nil) -> JevError?
    {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 402:
            return .noCredits(
                detailMessage(data) ?? "The TypeSafe organization has no credits left.")
        case 422: return .rejected(detailMessage(data) ?? "validation failed")
        case 429: return .rateLimited(after: retryAfter)
        case 529: return .overloaded
        default: return .http(status, String(decoding: data.prefix(512), as: UTF8.self))
        }
    }

    static func detailMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let detail = object["detail"] as? [String: Any],
            let message = detail["message"] as? String
        {
            return message
        }
        if let detail = object["detail"] as? String { return detail }
        if let details = object["detail"] as? [[String: Any]] {
            let messages = details.compactMap { $0["msg"] as? String }
            return messages.isEmpty ? nil : messages.joined(separator: "; ")
        }
        return nil
    }
}
