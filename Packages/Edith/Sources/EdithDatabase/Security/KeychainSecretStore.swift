import Foundation
import Security

struct DatabaseKeychainAPI: @unchecked Sendable {
    let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    static let live = DatabaseKeychainAPI(
        add: SecItemAdd,
        copyMatching: SecItemCopyMatching,
        update: SecItemUpdate,
        delete: SecItemDelete)
}

public actor DatabaseKeychainSecretStore: DatabaseSecretStore {
    public static let defaultService = "com.pulkit.edith.database"
    public static let defaultLabel = "Edith Database"

    public nonisolated let service: String
    public nonisolated let maximumSecretBytes: Int

    private let label: String
    private let keychain: DatabaseKeychainAPI

    public init(
        service: String = DatabaseKeychainSecretStore.defaultService,
        label: String = DatabaseKeychainSecretStore.defaultLabel,
        maximumSecretBytes: Int = DatabaseSecretStorageLimits.defaultMaximumBytes
    ) throws {
        try self.init(
            service: service,
            label: label,
            maximumSecretBytes: maximumSecretBytes,
            keychain: .live)
    }

    init(
        service: String,
        label: String,
        maximumSecretBytes: Int,
        keychain: DatabaseKeychainAPI
    ) throws {
        guard (1...255).contains(service.utf8.count) else {
            throw DatabaseSecretStoreError.invalidService
        }
        guard (1...128).contains(label.utf8.count) else {
            throw DatabaseSecretStoreError.invalidLabel
        }
        guard (1...DatabaseSecretStorageLimits.absoluteMaximumBytes).contains(maximumSecretBytes)
        else {
            throw DatabaseSecretStoreError.invalidMaximumSecretBytes
        }
        self.service = service
        self.label = label
        self.maximumSecretBytes = maximumSecretBytes
        self.keychain = keychain
    }

    public func store(_ secret: Data, for reference: DatabaseSecretReference) throws {
        try validate(secret)
        let query = itemQuery(reference)
        let attributes: [CFString: Any] = [kSecValueData: secret]
        let updateStatus = keychain.update(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData] = secret
            item[kSecAttrLabel] = label
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = keychain.add(item as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            if addStatus == errSecDuplicateItem {
                let retryStatus = keychain.update(
                    query as CFDictionary,
                    attributes as CFDictionary)
                if retryStatus == errSecSuccess { return }
                throw DatabaseSecretStoreError.keychainFailure(
                    operation: .store,
                    status: retryStatus)
            }
            throw DatabaseSecretStoreError.keychainFailure(
                operation: .store,
                status: addStatus)
        default:
            throw DatabaseSecretStoreError.keychainFailure(
                operation: .store,
                status: updateStatus)
        }
    }

    public func storeIfAbsent(
        _ secret: Data,
        for reference: DatabaseSecretReference
    ) throws -> Data {
        try validate(secret)
        var item = itemQuery(reference)
        item[kSecValueData] = secret
        item[kSecAttrLabel] = label
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = keychain.add(item as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return secret
        case errSecDuplicateItem:
            return try read(reference)
        default:
            throw DatabaseSecretStoreError.keychainFailure(
                operation: .store,
                status: status)
        }
    }

    public func read(_ reference: DatabaseSecretReference) throws -> Data {
        var query = itemQuery(reference)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw DatabaseSecretStoreError.invalidStoredData(reference)
            }
            guard data.count <= maximumSecretBytes else {
                throw DatabaseSecretStoreError.storedSecretTooLarge(
                    reference: reference,
                    maximumBytes: maximumSecretBytes)
            }
            return data
        case errSecItemNotFound:
            throw DatabaseSecretStoreError.notFound(reference)
        default:
            throw DatabaseSecretStoreError.keychainFailure(
                operation: .read,
                status: status)
        }
    }

    public func delete(_ reference: DatabaseSecretReference) throws {
        let status = keychain.delete(itemQuery(reference) as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw DatabaseSecretStoreError.notFound(reference)
        default:
            throw DatabaseSecretStoreError.keychainFailure(
                operation: .delete,
                status: status)
        }
    }

    public func contains(_ reference: DatabaseSecretReference) throws -> Bool {
        var query = itemQuery(reference)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw DatabaseSecretStoreError.keychainFailure(
                operation: .contains,
                status: status)
        }
    }

    static func account(for reference: DatabaseSecretReference) -> String {
        "\(reference.identifier.uuidString.lowercased()).\(reference.purpose.rawValue)"
    }

    private func itemQuery(_ reference: DatabaseSecretReference) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account(for: reference),
        ]
    }

    private func validate(_ secret: Data) throws {
        guard secret.count <= maximumSecretBytes else {
            throw DatabaseSecretStoreError.secretTooLarge(
                actualBytes: secret.count,
                maximumBytes: maximumSecretBytes)
        }
    }
}
