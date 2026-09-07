import EdithDatabase
import Foundation
import Security
import Testing

@testable import EdithDatabase

private final class DatabaseKeychainStub: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    lazy var api = DatabaseKeychainAPI(
        add: { [unowned self] query, _ in add(query) },
        copyMatching: { [unowned self] query, result in copy(query, result) },
        update: { [unowned self] query, attributes in update(query, attributes) },
        delete: { [unowned self] query in delete(query) })

    private func add(_ query: CFDictionary) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let key = key(query), let data = values(query)[kSecValueData] as? Data else {
            return errSecParam
        }
        guard values[key] == nil else { return errSecDuplicateItem }
        values[key] = data
        return errSecSuccess
    }

    private func copy(
        _ query: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let key = key(query), let data = values[key] else { return errSecItemNotFound }
        let queryValues = values(query)
        if queryValues[kSecReturnData] as? Bool == true {
            result?.pointee = data as CFData
        } else {
            result?.pointee = [kSecAttrAccount: key] as CFDictionary
        }
        return errSecSuccess
    }

    private func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let key = key(query), values[key] != nil else { return errSecItemNotFound }
        guard let data = values(attributes)[kSecValueData] as? Data else { return errSecParam }
        values[key] = data
        return errSecSuccess
    }

    private func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard let key = key(query), values.removeValue(forKey: key) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }

    private func key(_ query: CFDictionary) -> String? {
        let values = values(query)
        guard let service = values[kSecAttrService] as? String,
            let account = values[kSecAttrAccount] as? String
        else { return nil }
        return "\(service)|\(account)"
    }

    private func values(_ dictionary: CFDictionary) -> [CFString: Any] {
        dictionary as? [CFString: Any] ?? [:]
    }
}

@Suite struct DatabaseKeychainSecretStoreTests {
    @Test func storeReadUpdateContainsAndDeleteUseSecurityBoundary() async throws {
        let stub = DatabaseKeychainStub()
        let store = try DatabaseKeychainSecretStore(
            service: "com.pulkit.edith.tests.database.one",
            label: "Database tests",
            maximumSecretBytes: 128,
            keychain: stub.api)
        let reference = DatabaseSecretTestFixtures.password

        #expect(!(try await store.contains(reference)))
        try await store.store(DatabaseSecretTestFixtures.data("first"), for: reference)
        #expect(try await store.contains(reference))
        #expect(try await store.read(reference) == DatabaseSecretTestFixtures.data("first"))

        try await store.store(DatabaseSecretTestFixtures.data("second"), for: reference)
        #expect(try await store.read(reference) == DatabaseSecretTestFixtures.data("second"))

        try await store.delete(reference)
        #expect(!(try await store.contains(reference)))
    }

    @Test func explicitServicesIsolateTheSameReference() async throws {
        let stub = DatabaseKeychainStub()
        let first = try DatabaseKeychainSecretStore(
            service: "com.pulkit.edith.tests.database.first",
            label: "Database tests",
            maximumSecretBytes: 128,
            keychain: stub.api)
        let second = try DatabaseKeychainSecretStore(
            service: "com.pulkit.edith.tests.database.second",
            label: "Database tests",
            maximumSecretBytes: 128,
            keychain: stub.api)
        let reference = DatabaseSecretTestFixtures.password

        try await first.store(DatabaseSecretTestFixtures.data("first"), for: reference)
        try await second.store(DatabaseSecretTestFixtures.data("second"), for: reference)

        #expect(try await first.read(reference) == DatabaseSecretTestFixtures.data("first"))
        #expect(try await second.read(reference) == DatabaseSecretTestFixtures.data("second"))
    }

    @Test func storeIfAbsentUsesTheAtomicKeychainWinner() async throws {
        let stub = DatabaseKeychainStub()
        let first = try DatabaseKeychainSecretStore(
            service: "com.pulkit.edith.tests.database.atomic",
            label: "Database tests",
            maximumSecretBytes: 128,
            keychain: stub.api)
        let second = try DatabaseKeychainSecretStore(
            service: "com.pulkit.edith.tests.database.atomic",
            label: "Database tests",
            maximumSecretBytes: 128,
            keychain: stub.api)
        async let firstValue = first.storeIfAbsent(
            DatabaseSecretTestFixtures.data("first"),
            for: DatabaseSecretTestFixtures.token)
        async let secondValue = second.storeIfAbsent(
            DatabaseSecretTestFixtures.data("second"),
            for: DatabaseSecretTestFixtures.token)
        let values = try await [firstValue, secondValue]

        #expect(values[0] == values[1])
        #expect(try await first.read(DatabaseSecretTestFixtures.token) == values[0])
    }

    @Test func purposeIsPartOfTheBoundedAccountName() {
        let password = DatabaseKeychainSecretStore.account(
            for: DatabaseSecretTestFixtures.password)
        let token = DatabaseKeychainSecretStore.account(for: DatabaseSecretTestFixtures.token)
        let signingKey = DatabaseKeychainSecretStore.account(
            for: DatabaseSecretTestFixtures.confirmationSigningKey)
        let continuationSigningKey = DatabaseKeychainSecretStore.account(
            for: DatabaseSecretTestFixtures.continuationSigningKey)

        #expect(password != token)
        #expect(token != signingKey)
        #expect(signingKey != continuationSigningKey)
        #expect(password.hasSuffix(".password"))
        #expect(token.hasSuffix(".token"))
        #expect(signingKey.hasSuffix(".confirmationSigningKey"))
        #expect(continuationSigningKey.hasSuffix(".continuationSigningKey"))
        #expect(password.utf8.count < 128)
        #expect(signingKey.utf8.count < 128)
        #expect(continuationSigningKey.utf8.count < 128)
    }

    @Test func invalidConfigurationIsRejectedBeforeSecurityAccess() {
        #expect(throws: DatabaseSecretStoreError.invalidService) {
            try DatabaseKeychainSecretStore(service: "", label: "Database tests")
        }
        #expect(throws: DatabaseSecretStoreError.invalidLabel) {
            try DatabaseKeychainSecretStore(service: "valid", label: "")
        }
        #expect(throws: DatabaseSecretStoreError.invalidMaximumSecretBytes) {
            try DatabaseKeychainSecretStore(
                service: "valid",
                label: "Database tests",
                maximumSecretBytes: 0)
        }
    }

    @Test func missingReferencesReturnTypedErrors() async throws {
        let stub = DatabaseKeychainStub()
        let store = try DatabaseKeychainSecretStore(
            service: "com.pulkit.edith.tests.database.missing",
            label: "Database tests",
            maximumSecretBytes: 128,
            keychain: stub.api)
        let reference = DatabaseSecretTestFixtures.password

        await #expect(throws: DatabaseSecretStoreError.notFound(reference)) {
            try await store.read(reference)
        }
        await #expect(throws: DatabaseSecretStoreError.notFound(reference)) {
            try await store.delete(reference)
        }
    }
}
