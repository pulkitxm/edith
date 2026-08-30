import Darwin
import Foundation
import LocalAuthentication
import Security

enum ClaudeCredentialSource: Equatable {
    case keychain
    case file(URL)
    case shell
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

    static func transient(accessToken: String, maximumBytes: Int = 8_192)
        -> ClaudeOAuthCredential?
    {
        guard !accessToken.isEmpty, accessToken.utf8.count <= maximumBytes,
            accessToken.unicodeScalars.allSatisfy({ 0x21...0x7E ~= $0.value })
        else { return nil }
        return ClaudeOAuthCredential(
            accessToken: accessToken,
            refreshToken: nil,
            expiresAt: nil,
            refreshTokenExpiresAt: nil,
            source: .shell,
            document: [:])
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

enum ClaudeCredentialStoreError: LocalizedError, Equatable {
    case keychainUpdateFailed
    case transientCredential

    var errorDescription: String? {
        switch self {
        case .keychainUpdateFailed:
            return "Keychain update failed"
        case .transientCredential:
            return "Transient credentials cannot be persisted"
        }
    }
}

enum ClaudeCredentialDataLookup: Equatable {
    case data(Data)
    case missing
    case cancelled
    case timedOut
    case oversized
    case failed
}

enum ClaudeCredentialStore {
    typealias KeychainReader = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    typealias KeychainItemUpdater = (CFDictionary, CFDictionary) -> OSStatus
    typealias KeychainUpdater = (Data) throws -> Void

    private static let keychainService = "Claude Code-credentials"
    private static let maximumCredentialBytes = 65_536

    static func read() async -> ClaudeCredentialLookup {
        let keychain = keychainData()
        return read(
            home: FileManager.default.homeDirectoryForCurrentUser,
            keychainData: keychain,
            fileData: { credentialFileData(at: $0) })
    }

    static func read(
        home: URL,
        keychainData: ClaudeCredentialDataLookup,
        fileData: (URL) -> ClaudeCredentialDataLookup
    ) -> ClaudeCredentialLookup {
        let keychainFailure: ClaudeCredentialLookupFailure?
        switch keychainData {
        case .data(let data):
            if let credential = ClaudeOAuthCredential.decode(data, source: .keychain) {
                return .credential(credential)
            }
            keychainFailure = .malformed
        case .missing:
            keychainFailure = nil
        case .cancelled:
            return .cancelled
        case .timedOut:
            keychainFailure = .timedOut
        case .oversized:
            keychainFailure = .oversized
        case .failed:
            keychainFailure = .failed
        }
        let url = home.appendingPathComponent(".claude/.credentials.json")
        switch fileData(url) {
        case .data(let data):
            guard let credential = ClaudeOAuthCredential.decode(data, source: .file(url)) else {
                return .failure(.malformed)
            }
            return .credential(credential)
        case .missing:
            return .failure(keychainFailure ?? .missing)
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .failure(.timedOut)
        case .oversized:
            return .failure(.oversized)
        case .failed:
            return .failure(.failed)
        }
    }

    static func persist(_ data: Data, source: ClaudeCredentialSource) async throws {
        try await persist(data, source: source, keychainUpdater: { try updateKeychain($0) })
    }

    static func persist(
        _ data: Data, source: ClaudeCredentialSource, keychainUpdater: KeychainUpdater
    ) async throws {
        switch source {
        case .keychain:
            guard data.count <= maximumCredentialBytes else {
                throw ClaudeCredentialStoreError.keychainUpdateFailed
            }
            do {
                try keychainUpdater(data)
            } catch {
                throw ClaudeCredentialStoreError.keychainUpdateFailed
            }
        case .file(let url):
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        case .shell:
            throw ClaudeCredentialStoreError.transientCredential
        }
    }

    static func keychainData(
        maximumOutputBytes: Int = maximumCredentialBytes,
        readItem: KeychainReader = SecItemCopyMatching
    ) -> ClaudeCredentialDataLookup {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: noninteractiveContext(),
            kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        let status = readItem(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed }
            return data.count <= maximumOutputBytes ? .data(data) : .oversized
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled:
            return .cancelled
        default:
            return .failed
        }
    }

    static func credentialFileData(
        at url: URL, maximumOutputBytes: Int = maximumCredentialBytes
    ) -> ClaudeCredentialDataLookup {
        guard maximumOutputBytes >= 0, maximumOutputBytes < Int.max else { return .failed }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .failed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        do {
            defer { try? handle.close() }
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                return .failed
            }
            let data = try handle.read(upToCount: maximumOutputBytes + 1) ?? Data()
            guard data.count <= maximumOutputBytes else { return .oversized }
            return .data(data)
        } catch {
            return .failed
        }
    }

    static func updateKeychain(
        _ data: Data, updateItem: KeychainItemUpdater = SecItemUpdate
    ) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: NSUserName(),
            kSecAttrService: keychainService,
            kSecUseAuthenticationContext: noninteractiveContext(),
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        guard updateItem(query as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
            throw ClaudeCredentialStoreError.keychainUpdateFailed
        }
    }

    private static func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
