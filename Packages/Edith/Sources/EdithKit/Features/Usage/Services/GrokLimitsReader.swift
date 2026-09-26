import Foundation

enum GrokCredentialStore {
    struct Material: Equatable, Sendable {
        var storageKey: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var clientID: String
        var file: URL
    }

    static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Material? {
        let file = home.appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let candidates = object.compactMap { key, value -> Material? in
            guard let entry = value as? [String: Any],
                let accessToken = entry["key"] as? String, !accessToken.isEmpty
            else { return nil }
            let refresh = (entry["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let clientID =
                (entry["oidc_client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? key.split(separator: ":").last.map(String.init) ?? ""
            return Material(
                storageKey: key,
                accessToken: accessToken,
                refreshToken: refresh,
                expiresAt: (entry["expires_at"] as? String).flatMap(EdithDate.parseISO),
                clientID: clientID,
                file: file)
        }
        return candidates.max { lhs, rhs in
            (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
        }
    }

    static func save(_ material: Material) throws {
        let file = material.file
        var object =
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
            ?? [:]
        var entry = object[material.storageKey] as? [String: Any] ?? [:]
        entry["key"] = material.accessToken
        if let refreshToken = material.refreshToken { entry["refresh_token"] = refreshToken }
        if let expiresAt = material.expiresAt {
            entry["expires_at"] = timestamp(expiresAt)
        }
        object[material.storageKey] = entry
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = file.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func expiresSoon(
        _ expiry: Date?, now: Date = Date(), leeway: TimeInterval = 120
    ) -> Bool {
        guard let expiry else { return false }
        return expiry < now.addingTimeInterval(leeway)
    }

    static func tierDisplay(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let file = home.appendingPathComponent(".grok/settings_cache.json")
        guard let data = try? Data(contentsOf: file),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let payload = jsonObject(envelope["payload"]) ?? envelope
        let settings = jsonObject(payload["settings"]) ?? payload
        let display = nonempty(settings["subscription_tier_display"])
        let tier = nonempty(settings["subscription_tier"])
        return display ?? tier
    }

    private static func jsonObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String, let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return object
        }
        return nil
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum GrokLimitsReader {
    enum Failure: Error, Equatable, LocalizedError {
        case unauthorized
        case rateLimited(after: TimeInterval?)
        case unavailable
        case malformed
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Grok session expired. Run grok login."
            case .rateLimited: "Rate limited by Grok"
            case .unavailable: "Grok did not return an allowance."
            case .malformed: "Grok usage data is invalid"
            case .http: "Offline"
            }
        }
    }

    struct Refresh: Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func billingURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fallback = URL(
            string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        guard
            let raw = environment["GROK_CLI_CHAT_PROXY_BASE_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let base = URL(string: raw),
            base.scheme == "https",
            base.host != nil
        else { return fallback }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        return URL(string: trimmed + "/billing?format=credits") ?? fallback
    }

    static func fetch(token: String, tier: String?) async throws -> ProviderLimits {
        var request = URLRequest(url: billingURL())
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("xai-grok-build", forHTTPHeaderField: "User-Agent")
        request.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
        if let error = fetchError(statusCode: code, retryAfter: after) { throw error }
        return try limits(json: data, tier: tier)
    }

    static func refresh(refreshToken: String, clientID: String, now: Date = Date()) async throws
        -> Refresh
    {
        var request = URLRequest(url: URL(string: "https://auth.x.ai/oauth2/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = Data((parts.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
        if let error = fetchError(statusCode: code, retryAfter: after) { throw error }
        return try refreshed(json: data, now: now)
    }

    static func fetchError(statusCode: Int, retryAfter: TimeInterval? = nil) -> Failure? {
        switch statusCode {
        case 200: return nil
        case 401, 403: return .unauthorized
        case 429: return .rateLimited(after: retryAfter)
        default: return .http(statusCode)
        }
    }

    static func limits(json data: Data, tier: String?) throws -> ProviderLimits {
        guard data.count <= 1_048_576 else { throw Failure.malformed }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.malformed
            }
            object = parsed
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.malformed
        }
        let config = object["config"] as? [String: Any] ?? object
        guard let percent = number(config["creditUsagePercent"]) else { throw Failure.unavailable }
        let periodSource =
            (config["currentPeriod"] as? [String: Any])?["type"] as? String
        let period = GrokPeriod.canonical(periodSource)
        let resetText =
            ((config["currentPeriod"] as? [String: Any])?["end"] as? String)
            ?? (config["billingPeriodEnd"] as? String)
        let resetsAt = resetText.flatMap(EdithDate.parseISO)
        let products = (config["productUsage"] as? [[String: Any]] ?? []).compactMap {
            entry -> GrokProductShare? in
            guard let name = entry["product"] as? String, !name.isEmpty,
                let share = number(entry["usagePercent"])
            else { return nil }
            return GrokProductShare(name: productName(name), percent: share)
        }
        let allowance = GrokAllowance(
            period: period,
            tier: tier.flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            },
            products: products,
            onDemandUsed: number(config["onDemandUsed"]) ?? 0,
            onDemandCap: number(config["onDemandCap"]) ?? 0,
            prepaidBalance: number(config["prepaidBalance"]) ?? 0)
        return ProviderLimits(
            provider: .grok,
            session: nil,
            week: LimitWindow(percent: percent, resetsAt: resetsAt, period: period),
            grok: allowance)
    }

    static func refreshed(json data: Data, now: Date = Date()) throws -> Refresh {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.malformed
            }
            object = parsed
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.malformed
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw Failure.unauthorized
        }
        let refreshToken = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expiresIn = number(object["expires_in"]) ?? 3600
        return Refresh(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn))
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        if let object = value as? [String: Any] { return number(object["val"]) }
        return nil
    }

    private static func productName(_ raw: String) -> String {
        switch raw {
        case "GrokBuild", "Build": "Build"
        case "GrokChat", "Chat": "Chat"
        case "GrokImagine", "Imagine": "Imagine"
        case "GrokVoice", "Voice": "Voice"
        case "GrokAPI", "API", "Api": "API"
        default: raw
        }
    }
}
