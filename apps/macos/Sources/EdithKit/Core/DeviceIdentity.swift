import CryptoKit
import Foundation

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) -> Data? {
        guard !value.isEmpty,
            value.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            })
        else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

public protocol DeviceKeySigning {
    var publicKeyDER: Data { get }
    func signature(for message: Data) throws -> Data
}

struct SoftwareDeviceKey: DeviceKeySigning {
    let key: P256.Signing.PrivateKey

    var publicKeyDER: Data { key.publicKey.derRepresentation }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

struct SecureEnclaveDeviceKey: DeviceKeySigning {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKeyDER: Data { key.publicKey.derRepresentation }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

public protocol DeviceKeyStoring {
    func loadOrCreateKey() throws -> any DeviceKeySigning
}

public struct DeviceKeyStore: DeviceKeyStoring {
    static let secureEnclavePrefix = "se:"
    static let softwarePrefix = "sw:"

    private let store: any LicenseCredentialStoring
    private let secureEnclaveAvailable: Bool

    public init(
        store: any LicenseCredentialStoring,
        secureEnclaveAvailable: Bool = SecureEnclave.isAvailable
    ) {
        self.store = store
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    public func loadOrCreateKey() throws -> any DeviceKeySigning {
        if let stored = ((try? store.read(.deviceKey)) ?? nil), let key = decode(stored) {
            return key
        }
        return try createKey()
    }

    private func decode(_ stored: String) -> (any DeviceKeySigning)? {
        if stored.hasPrefix(Self.secureEnclavePrefix),
            let data = Data(base64Encoded: String(stored.dropFirst(3))),
            let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        {
            return SecureEnclaveDeviceKey(key: key)
        }
        if stored.hasPrefix(Self.softwarePrefix),
            let data = Data(base64Encoded: String(stored.dropFirst(3))),
            let key = try? P256.Signing.PrivateKey(rawRepresentation: data)
        {
            return SoftwareDeviceKey(key: key)
        }
        return nil
    }

    private func createKey() throws -> any DeviceKeySigning {
        if secureEnclaveAvailable,
            let key = try? SecureEnclave.P256.Signing.PrivateKey()
        {
            try store.write(
                Self.secureEnclavePrefix + key.dataRepresentation.base64EncodedString(),
                item: .deviceKey)
            return SecureEnclaveDeviceKey(key: key)
        }
        let key = P256.Signing.PrivateKey()
        try store.write(
            Self.softwarePrefix + key.rawRepresentation.base64EncodedString(),
            item: .deviceKey)
        return SoftwareDeviceKey(key: key)
    }
}

public struct DeviceIdentity {
    public let deviceId: String
    public let publicKeySPKIBase64URL: String
    public let thumbprint: String

    private let key: any DeviceKeySigning

    public init(
        credentialStore: any LicenseCredentialStoring,
        keyStore: any DeviceKeyStoring
    ) throws {
        if let stored = try credentialStore.read(.deviceId), !stored.isEmpty {
            deviceId = stored
        } else {
            let created = UUID().uuidString
            try credentialStore.write(created, item: .deviceId)
            deviceId = created
        }
        key = try keyStore.loadOrCreateKey()
        let spki = key.publicKeyDER
        publicKeySPKIBase64URL = Base64URL.encode(spki)
        thumbprint = Base64URL.encode(Data(SHA256.hash(data: spki)))
    }

    public func sign(message: Data) throws -> String {
        Base64URL.encode(try key.signature(for: message))
    }

    public static func challengeMessage(purpose: String, challengeId: String, nonce: String)
        -> Data
    {
        Data("edith-v2.\(purpose).\(challengeId).\(nonce)".utf8)
    }
}
