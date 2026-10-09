import Foundation
import LocalAuthentication
import Security

enum ClaudeSavedLogin {
    static func token(
        environment: [String: String] = UserShellEnvironment.userEnvironment(),
        now: Date = Date(),
        readFile: (URL) -> Data? = { try? Data(contentsOf: $0) },
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
