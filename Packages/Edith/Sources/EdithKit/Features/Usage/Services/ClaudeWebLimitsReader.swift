import Foundation

public enum ClaudeWebLimitsReader {
    public struct Credential: Equatable, Sendable {
        let sessionKey: String
        let organization: String?
    }

    public enum Failure: LocalizedError, Equatable, Sendable {
        case missingSession
        case browserAccess
        case keychainAccess
        case credentialTimeout
        case unauthorized
        case challenge
        case organization
        case unavailable
        case rateLimited(TimeInterval?)
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .missingSession:
                "Sign in to claude.ai in your active Chrome profile, then refresh limits."
            case .browserAccess:
                "Allow Edith to read Chrome data in macOS Privacy & Security, then refresh limits."
            case .keychainAccess:
                "Choose Connect Claude website in Agent Usage settings to allow Chrome Safe Storage access."
            case .credentialTimeout:
                "Chrome session lookup timed out. Choose Connect Claude website in Agent Usage settings."
            case .unauthorized:
                "Your Claude website session expired. Sign in to claude.ai, then refresh limits."
            case .challenge:
                "Claude's website requires browser verification. Open claude.ai and try again later."
            case .organization:
                "Claude's active organization could not be identified. Open claude.ai, then refresh limits."
            case .unavailable: "Claude's website did not return usage limits."
            case .rateLimited: "Claude's website rate limited the limits refresh."
            case .http(let code): "Claude's website returned HTTP \(code)."
            }
        }
    }

    actor ConnectionRequest {
        private var pending = false

        func request() { pending = true }
        func discard() { pending = false }
        func take() -> Bool {
            let result = pending
            pending = false
            return result
        }
    }

    private static let connectionRequest = ConnectionRequest()

    public static func requestConnection() async { await connectionRequest.request() }
    public static func discardConnection() async { await connectionRequest.discard() }

    private static let credentialLookup = BoundedKeychainAccess<Result<Credential, Failure>>()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    public static func fetch() async throws -> LimitsProviderSnapshot {
        let allowPrompt = await connectionRequest.take()
        let lookup = await credentialLookup.run(
            timeout: allowPrompt ? 60 : 3, fallback: .failure(.credentialTimeout)
        ) {
            do { return .success(try Self.credential(allowPrompt: allowPrompt)) } catch let failure
                as Failure
            {
                return .failure(failure)
            } catch { return .failure(.browserAccess) }
        }
        let credential = try lookup.get()
        return try await fetch(credential: credential) { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
            return (data, response)
        }
    }

    static func credential(
        userData: ChromeUserData = .standard, allowPrompt: Bool = false
    ) throws -> Credential {
        let profiles: [ChromeProfile]
        let active: String?
        do {
            profiles = try userData.profiles()
            let data = try Data(contentsOf: userData.localStateURL)
            let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            active = (state?["profile"] as? [String: Any])?["last_used"] as? String
        } catch { throw Failure.browserAccess }
        guard
            let profile = profiles.first(where: { $0.directory == active })
                ?? (profiles.count == 1 ? profiles.first : nil),
            let database = userData.cookiesURL(for: profile)
        else { throw Failure.missingSession }
        let key: ChromeCookieKey
        do { key = try ChromeSafeStorage.keychainKey(allowPrompt: allowPrompt) } catch {
            throw Failure.keychainAccess
        }
        let cookies: [ChromeCookie]
        do {
            cookies = try ChromeCookieReader.read(
                database: database, key: key, allowedHosts: ["claude.ai", ".claude.ai"])
        } catch { throw Failure.browserAccess }
        return try credential(cookies: cookies)
    }

    static func credential(cookies: [ChromeCookie]) throws -> Credential {
        let cookies = cookies.filter { ["claude.ai", ".claude.ai"].contains($0.host) }
            .sorted { $0.updated > $1.updated }
        guard let key = cookies.first(where: { $0.name == "sessionKey" })?.value,
            !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == ";" })
        else { throw Failure.missingSession }
        let organization = cookies.first(where: { $0.name == "lastActiveOrg" })?.value
        return Credential(sessionKey: key, organization: organization)
    }

    static func fetch(
        credential: Credential,
        send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> LimitsProviderSnapshot {
        let organizations = try await request("organizations", credential: credential, send: send)
        let organization = try organization(json: organizations, selected: credential.organization)
        let usage = try await request(
            "organizations/\(organization)/usage", credential: credential, send: send)
        return try limits(json: usage)
    }

    private static func request(
        _ path: String, credential: Credential,
        send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://claude.ai/api/\(path)")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("sessionKey=\(credential.sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200: return data
        case 401: throw Failure.unauthorized
        case 403:
            if response.value(forHTTPHeaderField: "cf-mitigated") == "challenge"
                || String(decoding: data.prefix(4096), as: UTF8.self).contains("Just a moment")
            {
                throw Failure.challenge
            }
            throw Failure.unauthorized
        case 429:
            let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Failure.rateLimited(after)
        default: throw Failure.http(response.statusCode)
        }
    }

    static func organization(json data: Data, selected: String?) throws -> String {
        struct Organization: Decodable { let uuid: String; let capabilities: [String]? }
        let organizations = try JSONDecoder().decode([Organization].self, from: data)
        let candidates = organizations.filter { $0.capabilities?.contains("chat") == true }
        let organization: Organization?
        if let selected {
            organization = organizations.first { $0.uuid == selected }
        } else {
            organization = candidates.count == 1 ? candidates.first : nil
        }
        guard let organization, UUID(uuidString: organization.uuid) != nil else {
            throw Failure.organization
        }
        return organization.uuid
    }

    static func limits(json data: Data) throws -> LimitsProviderSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unavailable
        }
        func window(_ value: Any?, field: String = "utilization") -> LimitWindow? {
            guard let value = value as? [String: Any], let percent = value[field] as? Double,
                percent.isFinite, percent >= 0
            else { return nil }
            return LimitWindow(
                percent: percent, resetsAt: EdithDate.parseISO(value["resets_at"] as? String))
        }
        let scoped = (object["limits"] as? [[String: Any]])?.first { limit in
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = model?["display_name"] as? String
            return limit["kind"] as? String == "weekly_scoped"
                && name?.lowercased().hasPrefix("fable") == true
        }
        let session = window(object["five_hour"])
        let week = window(object["seven_day"])
        let fable = window(object["seven_day_fable"]) ?? window(scoped, field: "percent")
        guard session != nil || week != nil || fable != nil else { throw Failure.unavailable }
        return LimitsProviderSnapshot(provider: .claude, session: session, week: week, fable: fable)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) { completionHandler(nil) }
    }
}
