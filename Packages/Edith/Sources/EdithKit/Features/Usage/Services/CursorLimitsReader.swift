import Foundation
import SQLite3

enum CursorCredentialStore {
    struct Material: Equatable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var file: URL?
    }

    static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Material? {
        let configHome =
            environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let files = [
            configHome.appendingPathComponent("cursor/auth.json"),
            home.appendingPathComponent(".cursor/auth.json"),
        ]
        for file in files {
            if let material = read(file: file) { return material }
        }
        return readDatabase(
            home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
    }

    static func save(_ material: Material) throws {
        guard let file = material.file else { return }
        var object =
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
            ?? [:]
        object["accessToken"] = material.accessToken
        if let refreshToken = material.refreshToken { object["refreshToken"] = refreshToken }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    static func expiresSoon(
        _ token: String, now: Date = Date(), leeway: TimeInterval = 120
    ) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry < now.addingTimeInterval(leeway)
    }

    static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONDecoder().decode(Claims.self, from: data),
            let exp = claims.exp, exp > 0
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private struct Claims: Decodable {
        let exp: Double?
    }

    private static func read(file: URL) -> Material? {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["accessToken"] as? String, !accessToken.isEmpty
        else { return nil }
        let refreshToken = (object["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Material(accessToken: accessToken, refreshToken: refreshToken, file: file)
    }

    private static func readDatabase(_ url: URL) -> Material? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle
        else { return nil }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        let sql =
            "SELECT key, value FROM ItemTable WHERE key IN "
            + "('cursorAuth/accessToken', 'cursorAuth/refreshToken')"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        var accessToken = ""
        var refreshToken: String?
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = text(statement, 0)
            let value = text(statement, 1)
            if key == "cursorAuth/accessToken" { accessToken = value }
            if key == "cursorAuth/refreshToken", !value.isEmpty { refreshToken = value }
        }
        guard !accessToken.isEmpty else { return nil }
        return Material(accessToken: accessToken, refreshToken: refreshToken, file: nil)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

enum CursorLimitsReader {
    enum Failure: Error, Equatable, LocalizedError {
        case unauthorized
        case rateLimited(after: TimeInterval?)
        case unavailable
        case malformed
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Cursor session expired - open Cursor and sign in"
            case .rateLimited: "Rate limited by Cursor"
            case .unavailable: "Cursor did not return a usage limit."
            case .malformed: "Cursor usage limit data is invalid"
            case .http: "Offline"
            }
        }
    }

    struct Refresh: Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func fetch(token: String) async throws -> ProviderLimits {
        var request = URLRequest(
            url: URL(
                string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
        if let error = fetchError(statusCode: code, retryAfter: after) { throw error }
        return try limits(json: data)
    }

    static func refresh(refreshToken: String) async throws -> Refresh {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
        if let error = fetchError(statusCode: code, retryAfter: after) { throw error }
        let body: TokenResponse
        do { body = try JSONDecoder().decode(TokenResponse.self, from: data) } catch {
            throw Failure.malformed
        }
        guard body.shouldLogout != true, let accessToken = body.accessToken, !accessToken.isEmpty
        else { throw Failure.unauthorized }
        let replacement = body.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        return Refresh(accessToken: accessToken, refreshToken: replacement)
    }

    static func fetchError(statusCode: Int, retryAfter: TimeInterval? = nil) -> Failure? {
        switch statusCode {
        case 200: return nil
        case 401, 403: return .unauthorized
        case 429: return .rateLimited(after: retryAfter)
        default: return .http(statusCode)
        }
    }

    static func limits(json data: Data) throws -> ProviderLimits {
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
        guard let plan = object["planUsage"] as? [String: Any] else { throw Failure.unavailable }
        let resetsAt = date(object["billingCycleEnd"])
        let models = percent(plan["autoPercentUsed"])
        let other = percent(plan["apiPercentUsed"])
        guard models != nil || other != nil else { throw Failure.unavailable }
        return ProviderLimits(
            provider: .cursor,
            session: models.map { LimitWindow(percent: $0, resetsAt: resetsAt) },
            week: other.map { LimitWindow(percent: $0, resetsAt: resetsAt) })
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let shouldLogout: Bool?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case shouldLogout
        }
    }

    private static func percent(_ value: Any?) -> Double? {
        guard let number = number(value), number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number.isFinite ? number : nil
        case let number as Int: return Double(number)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) { return date(from: number) }
        guard let text = value as? String else { return nil }
        if let number = Double(text) { return date(from: number) }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func date(from raw: Double) -> Date? {
        guard raw > 0, raw.isFinite else { return nil }
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
