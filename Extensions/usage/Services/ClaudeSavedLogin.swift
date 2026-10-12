import EdithExtensionSupport
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum UsageSavedLogin {
    static func scopedCredentials(
        directory: URL?,
        readKeychain: ([String: Any]) -> Data? = { query in
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
                return nil
            }
            return item as? Data
        }
    ) -> Data? {
        guard let directory else { return nil }
        let hash = SHA256.hash(data: Data(directory.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        let context = LAContext()
        context.interactionNotAllowed = true
        let value = readKeychain([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials-" + hash,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ])
        guard let value, value.count <= 65_536 else { return nil }
        return value
    }

    static func token(
        environment: [String: String] = UserShellEnvironment.userEnvironment(),
        now: Date = Date(),
        readFile: (URL) -> Data? = { url in
            guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            return try? file.read(upToCount: 65_537)
        },
        readKeychain: ([String: Any]) -> Data? = { query in
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
                return nil
            }
            return item as? Data
        }
    ) -> String? {
        let data: Data?
        if let directory = environment["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
            let url = URL(
                fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true
            )
            .appendingPathComponent(".credentials.json")
            data = readFile(url)
        } else {
            let context = LAContext()
            context.interactionNotAllowed = true
            data = readKeychain([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context,
            ])
        }
        guard let data, data.count <= 65_536,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let credential = object["claudeAiOauth"] as? [String: Any],
            let scopes = credential["scopes"] as? [String], scopes.contains("user:profile"),
            let expiry = credential["expiresAt"] as? Double, expiry.isFinite,
            expiry / 1000 > now.timeIntervalSince1970,
            let token = credential["accessToken"] as? String
        else { return nil }
        return try? ClaudeLimitsReader.validatedToken(token)
    }
}
