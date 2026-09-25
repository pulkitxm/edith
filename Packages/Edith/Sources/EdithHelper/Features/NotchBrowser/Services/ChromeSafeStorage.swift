import CommonCrypto
import CryptoKit
import Foundation
import Security

enum ChromeSafeStorageError: Error, Equatable, LocalizedError {
    case keychainDenied(OSStatus)
    case keychainMissing

    var errorDescription: String? {
        switch self {
        case .keychainDenied:
            "Keychain access to Chrome Safe Storage was not allowed."
        case .keychainMissing:
            "Chrome has no Safe Storage key in the keychain yet. Open Chrome once and try again."
        }
    }
}

struct ChromeCookieKey: Sendable, Equatable {
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    init(passphrase: String) {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let password = Array(passphrase.utf8)
        _ = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(passwordBuffer.baseAddress)?.assumingMemoryBound(
                        to: Int8.self), password.count,
                    saltBuffer.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        bytes = key
    }
}

enum ChromeSafeStorage {
    static let service = "Chrome Safe Storage"
    static let account = "Chrome"
    private static let versionPrefix = Array("v10".utf8)
    private static let initializationVector = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)

    static func keychainKey() throws -> ChromeCookieKey {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw ChromeSafeStorageError.keychainMissing }
        guard status == errSecSuccess, let data = result as? Data,
            let passphrase = String(data: data, encoding: .utf8), !passphrase.isEmpty
        else { throw ChromeSafeStorageError.keychainDenied(status) }
        return ChromeCookieKey(passphrase: passphrase)
    }

    static func decrypt(
        _ blob: Data, key: ChromeCookieKey, host: String, hashPrefixed: Bool
    ) -> String? {
        let bytes = [UInt8](blob)
        guard bytes.count > versionPrefix.count, Array(bytes.prefix(3)) == versionPrefix
        else { return nil }
        let body = Array(bytes.dropFirst(versionPrefix.count))
        guard body.count % kCCBlockSizeAES128 == 0,
            var plain = crypt(body, key: key, operation: CCOperation(kCCDecrypt))
        else { return nil }
        if hashPrefixed, plain.count >= 32 {
            let digest = Array(SHA256.hash(data: Data(host.utf8)))
            if Array(plain.prefix(32)) == digest { plain.removeFirst(32) }
        }
        return String(bytes: plain, encoding: .utf8)
    }

    static func encrypt(_ value: String, key: ChromeCookieKey, host: String?) -> Data? {
        var plain = [UInt8]()
        if let host { plain += Array(SHA256.hash(data: Data(host.utf8))) }
        plain += Array(value.utf8)
        guard let cipher = crypt(plain, key: key, operation: CCOperation(kCCEncrypt)) else {
            return nil
        }
        return Data(versionPrefix + cipher)
    }

    private static func crypt(_ input: [UInt8], key: ChromeCookieKey, operation: CCOperation)
        -> [UInt8]?
    {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            key.bytes, key.bytes.count, initializationVector, input, input.count, &output,
            output.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }
}
