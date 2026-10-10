import Foundation
import LocalAuthentication
import Security

enum JevKeyStores {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> any JevKeyStore
    {
        if environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil,
            let identifier = environment["EDITH_APPLICATION_IDENTIFIER"],
            identifier.hasPrefix("com.pulkit.edith.tests."),
            let suite = environment["EDITH_SHARED_DEFAULTS_SUITE"],
            suite == identifier + ".extensions.jev", let defaults = UserDefaults(suiteName: suite)
        {
            return FixtureJevKeyStore(defaults: defaults)
        }
        return KeychainJevKeyStore()
    }
}

struct FixtureJevKeyStore: JevKeyStore, @unchecked Sendable {
    let defaults: UserDefaults

    func read() -> JevKeyRead {
        guard let key = defaults.string(forKey: "syntheticJevKey"), !key.isEmpty else {
            return .missing
        }
        return .key(key)
    }

    func write(_ key: String?) -> Bool {
        defaults.set(key, forKey: "syntheticJevKey")
        return defaults.synchronize()
    }
}

struct KeychainJevKeyStore: JevKeyStore {
    static let account = "typesafe-api-key"
    static let service =
        (ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"]
            ?? "com.pulkit.edith.tests." + UUID().uuidString) + ".extensions.jev"
    let service: String

    init(service: String = Self.service) { self.service = service }

    func read() -> JevKeyRead {
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .missing }
            return .key(String(decoding: data, as: UTF8.self))
        case errSecItemNotFound: return .missing
        default: return .unreadable
        }
    }

    func write(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query() as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let value = Data(key.utf8)
        let status = SecItemUpdate(
            query() as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = baseQuery()
        item[kSecValueData as String] = value
        item[kSecAttrLabel as String] = "Edith Jev"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func query() -> [String: Any] {
        var query = baseQuery()
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
