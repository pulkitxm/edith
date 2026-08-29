import EdithDatabase
import Foundation
import Testing

@Suite struct DatabaseSecretRedactorTests {
    @Test func overlappingSecretsUseLongestSinglePassMatches() async throws {
        let store = try InMemoryDatabaseSecretStore()
        try await store.store(
            DatabaseSecretTestFixtures.data("abc"),
            for: DatabaseSecretTestFixtures.password)
        try await store.store(
            DatabaseSecretTestFixtures.data("token-abc"),
            for: DatabaseSecretTestFixtures.token)
        try await store.store(
            DatabaseSecretTestFixtures.data("[REDACTED]"),
            for: DatabaseSecretTestFixtures.apiKey)
        let redactor = try await DatabaseSecretRedactor(
            store: store,
            references: [
                DatabaseSecretTestFixtures.password,
                DatabaseSecretTestFixtures.token,
                DatabaseSecretTestFixtures.apiKey,
            ])

        let output = redactor.redact("token-abc abc [REDACTED]")

        #expect(output == "[REDACTED] [REDACTED] [REDACTED]")
        #expect(!output.contains("abc"))
        #expect(String(describing: redactor) == "DatabaseSecretRedactor")
        #expect(String(reflecting: redactor) == "DatabaseSecretRedactor")
    }

    @Test func recursivelyRedactsEveryTextualAndBinaryValueSurface() async throws {
        let store = try InMemoryDatabaseSecretStore()
        try await store.store(
            DatabaseSecretTestFixtures.data("private-token"),
            for: DatabaseSecretTestFixtures.token)
        let redactor = try await DatabaseSecretRedactor(
            store: store,
            references: [DatabaseSecretTestFixtures.token])
        let value = DatabaseValue.object([
            DatabaseObjectField(
                name: "private-token-field",
                value: .array([
                    .string("prefix private-token suffix"),
                    .binary(
                        .complete(
                            data: DatabaseSecretTestFixtures.data("bytes-private-token"),
                            mediaType: "private-token/type",
                            digest: "private-token-digest")),
                    .date(
                        DatabaseDateValue(
                            text: "private-token",
                            calendarIdentifier: "private-token-calendar")),
                    .timestamp(
                        DatabaseTimestampValue(
                            text: "private-token",
                            timeZoneIdentifier: "private-token-zone")),
                    .productSpecific(
                        DatabaseProductValue(
                            product: .postgresql,
                            typeName: "private-token-type",
                            textRepresentation: "private-token-value",
                            binaryRepresentation: DatabaseSecretTestFixtures.data("private-token"),
                            attributes: [
                                DatabaseStringAttribute(
                                    name: "private-token-name",
                                    value: "private-token-attribute")
                            ])),
                ]))
        ])

        let redacted = redactor.redact(value)
        let encoded = try JSONEncoder().encode(redacted)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains("private-token"))
        #expect(text.contains("[REDACTED]"))
    }

    @Test func binaryRedactionPreservesUnrelatedBytes() async throws {
        let store = try InMemoryDatabaseSecretStore()
        try await store.store(Data([1, 2, 3]), for: DatabaseSecretTestFixtures.password)
        let redactor = try await DatabaseSecretRedactor(
            store: store,
            references: [DatabaseSecretTestFixtures.password],
            replacement: "x")

        #expect(redactor.redact(Data([0, 1, 2, 3, 4])) == Data([0, 120, 4]))
    }

    @Test func missingReferencesStopRedactorConstruction() async throws {
        let store = try InMemoryDatabaseSecretStore()
        let reference = DatabaseSecretTestFixtures.password

        await #expect(throws: DatabaseSecretStoreError.notFound(reference)) {
            try await DatabaseSecretRedactor(store: store, references: [reference])
        }
    }

    @Test func emptySecretsAreIgnoredAndLimitsAreTyped() async throws {
        let store = try InMemoryDatabaseSecretStore()
        try await store.store(Data(), for: DatabaseSecretTestFixtures.password)
        let redactor = try await DatabaseSecretRedactor(
            store: store,
            references: [DatabaseSecretTestFixtures.password])

        #expect(redactor.redact("unchanged") == "unchanged")
        await #expect(throws: DatabaseSecretRedactorError.invalidReplacement) {
            try await DatabaseSecretRedactor(
                store: store,
                references: [],
                replacement: "")
        }
        await #expect(
            throws: DatabaseSecretRedactorError.tooManyReferences(
                actual: DatabaseSecretRedactor.maximumReferences + 1,
                maximum: DatabaseSecretRedactor.maximumReferences)
        ) {
            try await DatabaseSecretRedactor(
                store: store,
                references: Array(
                    repeating: DatabaseSecretTestFixtures.password,
                    count: DatabaseSecretRedactor.maximumReferences + 1))
        }
    }
}
