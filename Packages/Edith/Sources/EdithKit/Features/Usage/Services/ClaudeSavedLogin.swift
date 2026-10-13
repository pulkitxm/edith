import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum ClaudeSavedLogin {
    static func scopedToken(account: ClaudeAccount, directory: URL) async -> String? {
        let folder = directory.appendingPathComponent(account.id.uuidString).path
        if let data = await ClaudeLimitsLogin.credentials(folder: URL(fileURLWithPath: folder)),
            let local = token(
                environment: ["CLAUDE_CONFIG_DIR": folder], readFile: { _ in data })
        {
            return local
        }
        if let loginData = account.loginData,
            let imported = token(
                environment: ["CLAUDE_CONFIG_DIR": "/account"],
                readFile: { _ in Data(loginData.utf8) })
        {
            return imported
        }
        for machine in MachineRegistry.machines() {
            let connection = SSHConnection(
                machine: machine, controlSocketMode: .shared, connectTimeout: 3)
            guard (try? await connection.connect()) != nil,
                await connection.remotePlatform != .windows
            else { continue }
            guard
                let result = try? await connection.run(
                    "head -c 65537 \"$HOME/.local/share/edith/accounts/\(account.id.uuidString)/.credentials.json\"",
                    timeout: 5), result.succeeded
            else { continue }
            if let remote = token(
                environment: ["CLAUDE_CONFIG_DIR": "/account"], readFile: { _ in result.stdout })
            {
                return remote
            }
        }
        return nil
    }

    public static func token(
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
        guard
            let data = credentials(
                environment: environment, readFile: readFile, readKeychain: readKeychain),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let credential = object["claudeAiOauth"] as? [String: Any],
            let scopes = credential["scopes"] as? [String], scopes.contains("user:profile"),
            let expiry = credential["expiresAt"] as? Double, expiry.isFinite,
            expiry / 1000 > now.timeIntervalSince1970,
            let token = credential["accessToken"] as? String
        else { return nil }
        return try? ClaudeLimitsReader.validatedToken(token)
    }

    public static func credentials(
        environment: [String: String] = UserShellEnvironment.userEnvironment(),
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
    ) -> Data? {
        let data: Data?
        if let directory = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], !directory.isEmpty {
            let hash = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }
                .joined().prefix(8)
            let context = LAContext()
            context.interactionNotAllowed = true
            data =
                readKeychain([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "Claude Code-credentials-" + hash,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecUseAuthenticationContext as String: context,
                ])
                ?? readFile(
                    URL(fileURLWithPath: directory).appendingPathComponent(".credentials.json"))
        } else if let directory = environment["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
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
        guard let data, data.count <= 65_536 else { return nil }
        return data
    }
}
