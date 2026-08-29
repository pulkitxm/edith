import EdithDatabase
import Foundation
import Testing

@Suite struct InMemoryDatabaseSecretStoreTests {
    @Test func storeReadUpdateAndDelete() async throws {
        let store = try InMemoryDatabaseSecretStore()
        let reference = DatabaseSecretTestFixtures.password

        #expect(!(await store.contains(reference)))
        try await store.store(DatabaseSecretTestFixtures.data("first"), for: reference)
        #expect(await store.contains(reference))
        #expect(try await store.read(reference) == DatabaseSecretTestFixtures.data("first"))

        try await store.store(DatabaseSecretTestFixtures.data("second"), for: reference)
        #expect(try await store.read(reference) == DatabaseSecretTestFixtures.data("second"))

        try await store.delete(reference)
        #expect(!(await store.contains(reference)))
    }

    @Test func missingReferencesReturnTypedErrors() async throws {
        let store = try InMemoryDatabaseSecretStore()
        let reference = DatabaseSecretTestFixtures.password

        await #expect(throws: DatabaseSecretStoreError.notFound(reference)) {
            try await store.read(reference)
        }
        await #expect(throws: DatabaseSecretStoreError.notFound(reference)) {
            try await store.delete(reference)
        }
    }

    @Test func storesAreIsolatedWithTheSameReference() async throws {
        let first = try InMemoryDatabaseSecretStore()
        let second = try InMemoryDatabaseSecretStore()
        let reference = DatabaseSecretTestFixtures.password

        try await first.store(DatabaseSecretTestFixtures.data("first"), for: reference)
        try await second.store(DatabaseSecretTestFixtures.data("second"), for: reference)

        #expect(try await first.read(reference) == DatabaseSecretTestFixtures.data("first"))
        #expect(try await second.read(reference) == DatabaseSecretTestFixtures.data("second"))
    }

    @Test func storeIfAbsentReturnsTheSinglePersistedValue() async throws {
        let store = try InMemoryDatabaseSecretStore()
        let reference = DatabaseSecretTestFixtures.token
        let first = try await store.storeIfAbsent(
            DatabaseSecretTestFixtures.data("first"),
            for: reference)
        let second = try await store.storeIfAbsent(
            DatabaseSecretTestFixtures.data("second"),
            for: reference)

        #expect(first == DatabaseSecretTestFixtures.data("first"))
        #expect(second == first)
        #expect(try await store.read(reference) == first)
    }

    @Test func purposesKeepReferencesWithTheSameIdentifierSeparate() async throws {
        let store = try InMemoryDatabaseSecretStore()

        try await store.store(
            DatabaseSecretTestFixtures.data("password"),
            for: DatabaseSecretTestFixtures.password)
        try await store.store(
            DatabaseSecretTestFixtures.data("token"),
            for: DatabaseSecretTestFixtures.token)

        #expect(
            try await store.read(DatabaseSecretTestFixtures.password)
                == DatabaseSecretTestFixtures.data("password"))
        #expect(
            try await store.read(DatabaseSecretTestFixtures.token)
                == DatabaseSecretTestFixtures.data("token"))
    }

    @Test func secretSizeLimitsApplyToInitialAndUpdatedValues() async throws {
        #expect(throws: DatabaseSecretStoreError.invalidMaximumSecretBytes) {
            try InMemoryDatabaseSecretStore(maximumSecretBytes: 0)
        }
        #expect(
            throws: DatabaseSecretStoreError.secretTooLarge(
                actualBytes: 5,
                maximumBytes: 4)
        ) {
            try InMemoryDatabaseSecretStore(
                initialValues: [DatabaseSecretTestFixtures.password: Data(repeating: 1, count: 5)],
                maximumSecretBytes: 4)
        }

        let store = try InMemoryDatabaseSecretStore(maximumSecretBytes: 4)
        await #expect(
            throws: DatabaseSecretStoreError.secretTooLarge(
                actualBytes: 5,
                maximumBytes: 4)
        ) {
            try await store.store(
                Data(repeating: 1, count: 5),
                for: DatabaseSecretTestFixtures.password)
        }
    }
}
