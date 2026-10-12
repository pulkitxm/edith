import Foundation

public enum ClaudeSavedLogin {
    public static func scopedToken(
        account: ClaudeAccount, directory: URL, now: Date = Date(),
        readScopedSecret: (URL?) -> Data? = { _ in nil }
    ) -> String? {
        guard !account.isLoggedOut, !Task.isCancelled else { return nil }
        let local: Data?
        do {
            local = try ClaudeAccountStorage.localCredentials(
                account: account, directory: directory)
        } catch {
            return nil
        }
        let profile = directory.appendingPathComponent(account.id.uuidString, isDirectory: true)
        guard !Task.isCancelled else { return nil }
        if let data = readScopedSecret(profile) ?? local {
            return token(data: data, now: now)
        }
        guard let loginData = account.loginData else { return nil }
        return token(data: Data(loginData.utf8), now: now)
    }

    public static func credentials(
        environment: [String: String], readFile: (URL) -> Data?,
        readScopedSecret: (URL?) -> Data?
    ) -> Data? {
        let data: Data?
        if let path = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], !path.isEmpty {
            guard !path.utf8.contains(0) else { return nil }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            data =
                readScopedSecret(directory)
                ?? readFile(directory.appendingPathComponent(".credentials.json"))
        } else if let path = environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            guard !path.utf8.contains(0) else { return nil }
            data = readFile(
                URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                    .appendingPathComponent(".credentials.json"))
        } else {
            data = readScopedSecret(nil)
        }
        guard let data, data.count <= 65_536 else { return nil }
        return data
    }

    public static func token(data: Data, now: Date = Date()) -> String? {
        guard data.count <= 65_536,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let login = object["claudeAiOauth"] as? [String: Any],
            let scopes = login["scopes"] as? [String], scopes.contains("user:profile"),
            let expiry = login["expiresAt"] as? Double, expiry.isFinite,
            expiry / 1000 > now.timeIntervalSince1970,
            let token = login["accessToken"] as? String, !token.isEmpty,
            token.utf8.count <= 8192,
            token.unicodeScalars.allSatisfy({ 0x21...0x7E ~= $0.value })
        else { return nil }
        return token
    }
}
