import CryptoKit
import Foundation

public actor ClaudeLimitsLogin {
    public static let shared = ClaudeLimitsLogin()
    private var pending: [String: Task<String, Error>] = [:]
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(
            configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    public func token(folder: URL) async throws -> String {
        if let task = pending[folder.path] { return try await task.value }
        let task = Task<String, Error> {
            guard let data = await Self.credentials(folder: folder) else {
                throw ClaudeAccountError.rejected(
                    "Complete the subscription sign-in in the limits terminal, then refresh limits."
                )
            }
            if let token = ClaudeSavedLogin.token(
                environment: ["CLAUDE_CONFIG_DIR": folder.path], now: Date().addingTimeInterval(60),
                readFile: { _ in data })
            {
                return token
            }
            let updated = try await Self.renew(credentials: data) { request in
                let (data, response) = try await Self.session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw ClaudeLimitsReader.Failure.unavailable
                }
                return (data, response)
            }
            try await Self.save(updated, folder: folder)
            guard
                let token = ClaudeSavedLogin.token(
                    environment: ["CLAUDE_CONFIG_DIR": folder.path], readFile: { _ in updated })
            else {
                throw ClaudeLimitsReader.Failure.unauthorized
            }
            return token
        }
        pending[folder.path] = task
        defer { pending.removeValue(forKey: folder.path) }
        return try await task.value
    }

    static func renew(
        credentials: Data, now: Date = Date(),
        send: (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> Data {
        guard credentials.count <= 65_536,
            var object = try JSONSerialization.jsonObject(with: credentials) as? [String: Any],
            var login = object["claudeAiOauth"] as? [String: Any],
            let scopes = login["scopes"] as? [String], scopes.contains("user:profile")
        else { throw ClaudeLimitsReader.Failure.missingProfileScope }
        guard let refreshToken = login["refreshToken"] as? String else {
            throw ClaudeLimitsReader.Failure.unauthorized
        }
        _ = try ClaudeLimitsReader.validatedToken(refreshToken)
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": login["clientId"] as? String ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": scopes.joined(separator: " "),
        ])
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200: break
        case 400, 401, 403: throw ClaudeLimitsReader.Failure.unauthorized
        case 429:
            throw ClaudeLimitsReader.Failure.rateLimited(
                response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw ClaudeLimitsReader.Failure.http(response.statusCode)
        }
        guard data.count <= 65_536,
            let renewed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = renewed["access_token"] as? String,
            let lifetime = renewed["expires_in"] as? Double, lifetime.isFinite, lifetime > 0,
            let granted = renewed["scope"] as? String,
            granted.split(separator: " ").contains("user:profile")
        else { throw ClaudeLimitsReader.Failure.unauthorized }
        _ = try ClaudeLimitsReader.validatedToken(accessToken)
        login["accessToken"] = accessToken
        login["expiresAt"] = now.addingTimeInterval(lifetime).timeIntervalSince1970 * 1000
        login["scopes"] = granted.split(separator: " ").map(String.init)
        if let rotated = renewed["refresh_token"] as? String {
            _ = try ClaudeLimitsReader.validatedToken(rotated)
            login["refreshToken"] = rotated
        }
        object["claudeAiOauth"] = login
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func service(_ folder: URL) -> String {
        let hash = SHA256.hash(data: Data(folder.path.utf8)).map { String(format: "%02x", $0) }
            .joined().prefix(8)
        return "Claude Code-credentials-" + hash
    }

    static func credentials(folder: URL) async -> Data? {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-a", NSUserName(), "-s", service(folder), "-w"],
            environment: [:], timeout: 3, maximumOutputBytes: 65_537,
            discardsStandardError: true)
        if let result = try? await CLICommandRunner.runLocal(request, onLine: { _ in }),
            result.terminationStatus == 0,
            let object = try? JSONSerialization.jsonObject(with: result.standardOutputData),
            let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 65_536
        {
            return data
        }
        return ClaudeSavedLogin.credentials(environment: ["CLAUDE_CONFIG_DIR": folder.path])
    }

    static func save(_ data: Data, folder: URL) async throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let input =
            "add-generic-password -U -a " + ShellQuote.quote(NSUserName())
            + " -s " + ShellQuote.quote(service(folder)) + " -X " + ShellQuote.quote(hex) + "\n"
        let result = try await CLICommandRunner.runLocal(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/security"), arguments: ["-i"],
                environment: [:], timeout: 3, maximumOutputBytes: 1024,
                standardInputData: Data(input.utf8), discardsStandardError: true),
            onLine: { _ in })
        guard result.terminationStatus == 0 else {
            throw ClaudeAccountError.rejected("Could not save the renewed limits login.")
        }
        let file = folder.appendingPathComponent(".credentials.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
