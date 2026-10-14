import CryptoKit
import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation

enum ClaudeLimitsLogin {
    struct Services: Sendable {
        var readNative: @Sendable (URL) async throws -> Data?
        var writeNative: @Sendable (URL, Data) async throws -> Void
        var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        var now: @Sendable () -> Date = { Date() }
    }

    static let services = Services(
        readNative: { try await nativeCredentials(folder: $0) },
        writeNative: { try await saveNative($1, folder: $0) },
        send: { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await UsageHTTPResponse.read(
                request, session: session, maximumBytes: 65_536, delegate: RedirectPolicy())
            guard let response = response as? HTTPURLResponse else {
                throw ClaudeLimitsReader.Failure.unavailable
            }
            return (data, response)
        })

    static func token(
        account: ClaudeAccount, directory: URL, services: Services = ClaudeLimitsLogin.services
    ) async throws -> String {
        let storage = ClaudeAccountStorage(directory: directory)
        let (folder, previousFile) = try await storage.limitsLoginCredentials(account: account)
        let native: Data?
        do {
            native = try await services.readNative(folder)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            native = nil
        }
        try Task.checkCancellation()
        guard try await storage.limitsLoginCredentials(account: account).1 == previousFile,
            let data = native ?? previousFile, data.count <= 65_536
        else {
            throw ClaudeAccountError.rejected(
                "Complete the subscription sign-in in the limits terminal, then refresh limits.")
        }
        let now = services.now()
        if let token = ClaudeSavedLogin.token(data: data, now: now.addingTimeInterval(60)) {
            return token
        }
        let updated = try await renew(data, now: now, send: services.send)
        try Task.checkCancellation()
        guard try await storage.limitsLoginCredentials(account: account).1 == previousFile else {
            throw CancellationError()
        }
        try await storage.renewLimitsLogin(
            account: account, expected: previousFile, data: updated,
            writeScopedSecret: services.writeNative)
        guard let token = ClaudeSavedLogin.token(data: updated, now: services.now()) else {
            throw ClaudeLimitsReader.Failure.unauthorized
        }
        return token
    }

    static func renew(
        _ data: Data, now: Date,
        send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> Data {
        try Task.checkCancellation()
        guard data.count <= 65_536,
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var oauth = object["claudeAiOauth"] as? [String: Any],
            let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile"),
            let refresh = oauth["refreshToken"] as? String
        else { throw ClaudeLimitsReader.Failure.unauthorized }
        _ = try ClaudeLimitsReader.validatedToken(refresh)
        let client = oauth["clientId"] as? String ?? "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        guard client.utf8.count <= 128 else { throw ClaudeLimitsReader.Failure.invalidToken }
        _ = try ClaudeLimitsReader.validatedToken(client)
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": client,
            "scope": "user:profile",
        ])
        let (responseData, response) = try await send(request)
        try Task.checkCancellation()
        guard responseData.count <= 65_536 else { throw ClaudeLimitsReader.Failure.unavailable }
        switch response.statusCode {
        case 200: break
        case 400, 401, 403: throw ClaudeLimitsReader.Failure.unauthorized
        case 429:
            throw ClaudeLimitsReader.Failure.rateLimited(
                response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        default: throw ClaudeLimitsReader.Failure.http(response.statusCode)
        }
        guard let value = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let access = value["access_token"] as? String,
            let lifetime = value["expires_in"] as? Double, lifetime.isFinite, lifetime > 0,
            let scope = value["scope"] as? String, scope.utf8.count <= 8192
        else { throw ClaudeLimitsReader.Failure.unauthorized }
        _ = try ClaudeLimitsReader.validatedToken(access)
        let granted = scope.split(separator: " ").map(String.init)
        let expiry = now.addingTimeInterval(lifetime).timeIntervalSince1970 * 1000
        guard expiry.isFinite, granted.count <= 64, granted.contains("user:profile") else {
            throw ClaudeLimitsReader.Failure.missingProfileScope
        }
        oauth["accessToken"] = access
        oauth["expiresAt"] = expiry
        oauth["scopes"] = granted
        if let rotated = value["refresh_token"] as? String {
            _ = try ClaudeLimitsReader.validatedToken(rotated)
            oauth["refreshToken"] = rotated
        }
        object["claudeAiOauth"] = oauth
        let updated = try JSONSerialization.data(withJSONObject: object)
        guard updated.count <= 65_536 else { throw ClaudeLimitsReader.Failure.unavailable }
        return updated
    }

    static func service(_ folder: URL) -> String {
        let hash = SHA256.hash(data: Data(folder.path.utf8)).map { String(format: "%02x", $0) }
            .joined().prefix(8)
        return "Claude Code-credentials-" + hash
    }

    static func nativeCredentials(
        folder: URL, username: String = NSUserName(),
        run: ToolVersionProbe.RunCommand = { try await CLICommandRunner.runLocal($0, onLine: $1) }
    ) async throws -> Data? {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-a", username, "-s", service(folder), "-w"],
            environment: [:], timeout: 3, maximumOutputBytes: 65_537,
            discardsStandardError: true)
        let result = try await run(request, { _ in })
        try Task.checkCancellation()
        guard result.terminationStatus == 0, result.standardOutputData.count <= 65_536,
            let object = try? JSONSerialization.jsonObject(with: result.standardOutputData),
            let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 65_536
        else { return nil }
        return data
    }

    static func saveNative(
        _ data: Data, folder: URL, username: String = NSUserName(),
        run: ToolVersionProbe.RunCommand = { try await CLICommandRunner.runLocal($0, onLine: $1) }
    ) async throws {
        guard data.count <= 65_536 else { throw ClaudeAccountError.invalidRequest }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let input =
            "add-generic-password -U -a " + ShellQuote.quote(username)
            + " -s " + ShellQuote.quote(service(folder)) + " -X " + ShellQuote.quote(hex) + "\n"
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"), arguments: ["-i"],
            environment: [:], timeout: 3, maximumOutputBytes: 1024,
            standardInputData: Data(input.utf8), discardsStandardError: true)
        let result = try await run(request, { _ in })
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            throw ClaudeAccountError.rejected("Could not save the renewed limits login.")
        }
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
