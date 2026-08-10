import Foundation

enum ClaudeCredentialSource: Equatable {
    case keychain
    case file(URL)
}

struct ClaudeOAuthCredential {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let refreshTokenExpiresAt: Date?
    let source: ClaudeCredentialSource
    private let document: [String: Any]

    static func decode(_ data: Data, source: ClaudeCredentialSource) -> ClaudeOAuthCredential? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = document["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else { return nil }
        return ClaudeOAuthCredential(
            accessToken: accessToken,
            refreshToken: nonempty(oauth["refreshToken"] as? String),
            expiresAt: millisecondsDate(oauth["expiresAt"]),
            refreshTokenExpiresAt: millisecondsDate(oauth["refreshTokenExpiresAt"]),
            source: source,
            document: document)
    }

    func shouldRefresh(at now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }

    func usableRefreshToken(at now: Date) -> String? {
        guard let refreshToken else { return nil }
        if let refreshTokenExpiresAt, refreshTokenExpiresAt <= now { return nil }
        return refreshToken
    }

    func updatedData(with response: ClaudeOAuthRefreshResponse, now: Date) throws -> Data {
        var updated = document
        var oauth = updated["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = response.accessToken
        oauth["expiresAt"] = Int64(
            now.addingTimeInterval(response.expiresIn).timeIntervalSince1970 * 1000)
        if let refreshToken = response.refreshToken, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        if let refreshTokenExpiresIn = response.refreshTokenExpiresIn {
            oauth["refreshTokenExpiresAt"] = Int64(
                now.addingTimeInterval(refreshTokenExpiresIn).timeIntervalSince1970 * 1000)
        }
        updated["claudeAiOauth"] = oauth
        return try JSONSerialization.data(withJSONObject: updated)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func millisecondsDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

struct ClaudeOAuthRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let refreshTokenExpiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
    }
}

enum ClaudeCredentialStoreError: LocalizedError {
    case keychainUpdateFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .keychainUpdateFailed(let status):
            return "Keychain update failed with status \(status)"
        }
    }
}

enum ClaudeCredentialStore {
    private static let keychainService = "Claude Code-credentials"

    static func read() -> ClaudeOAuthCredential? {
        if let data = keychainData(),
            let credential = ClaudeOAuthCredential.decode(data, source: .keychain)
        {
            return credential
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeOAuthCredential.decode(data, source: .file(url))
    }

    static func persist(_ data: Data, source: ClaudeCredentialSource) throws {
        switch source {
        case .keychain:
            try updateKeychain(data)
        case .file(let url):
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func updateKeychain(_ data: Data) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U", "-a", NSUserName(), "-s", keychainService, "-w",
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data("\n".utf8))
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data("\n".utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeCredentialStoreError.keychainUpdateFailed(process.terminationStatus)
        }
    }
}
