import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

public enum ClaudeAccountKeychain {
    public static func service(profile: URL?) -> String {
        guard let profile else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(profile.path.utf8)).map { String(format: "%02x", $0) }
            .joined().prefix(8)
        return "Claude Code-credentials-" + hash
    }

    public static func readScopedSecret(_ profile: URL?) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(profile: profile),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, data.count <= 65_536
        {
            return data
        }
        guard profile == nil else { return nil }
        return readFile(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".claude/.credentials.json"))
    }

    public static func eraseScopedSecret(_ profile: URL) throws {
        let result = SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service(profile: profile),
            ] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw ClaudeAccountError.rejected("The account login could not be removed. Try again.")
        }
    }

    public static func credentials(environment: [String: String]) -> Data? {
        ClaudeSavedLogin.credentials(
            environment: environment, readFile: readFile, readScopedSecret: readScopedSecret)
    }

    static func absoluteComponents(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.utf8.count <= 8192, !path.utf8.contains(0),
            parts.count > 1,
            parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return parts.dropFirst().map(String.init)
    }

    public static func readFile(_ url: URL) -> Data? {
        guard url.isFileURL, let names = absoluteComponents(url.path), let name = names.last
        else { return nil }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        for component in names.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(parent)
            parent = next
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_mode & 0o777 == 0o600,
            metadata.st_size >= 0, metadata.st_size <= 65_536,
            let data = try? file.read(upToCount: 65_537), data.count <= 65_536
        else { return nil }
        return data
    }
}
