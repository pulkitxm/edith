import EdithDatabase
import Foundation
import Testing

@Suite("Database connection draft")
struct DatabaseConnectionDraftTests {
    @Test("PostgreSQL creates a safe password connection")
    func postgreSQL() throws {
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let draft = DatabaseConnectionDraft(
            displayName: "TUF PostgreSQL",
            product: .postgresql,
            host: "127.0.0.1",
            port: 15_432,
            username: "edith",
            database: "million_rows",
            passwordReference: reference)

        let definition = try draft.definition(createdAt: Date(timeIntervalSince1970: 1_000))

        #expect(definition.displayName == "TUF PostgreSQL")
        #expect(definition.authentication.kind == .usernameAndPassword)
        #expect(definition.authentication.secretReferences == [reference])
        #expect(definition.namespaces.database == "million_rows")
        #expect(definition.readOnlyPolicy == .required)
        #expect(definition.environment.protection == .confirmationRequired)
    }

    @Test("Redis creates password-only authentication and database zero")
    func redis() throws {
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let draft = DatabaseConnectionDraft(
            displayName: "TUF Redis",
            product: .redis,
            passwordReference: reference)

        let definition = try draft.definition()

        #expect(definition.authentication.kind == .password)
        #expect(definition.namespaces.logicalDatabase == "0")
        #expect(definition.tls.mode == .disabled)
    }

    @Test("MongoDB uses SCRAM and an authentication source")
    func mongoDB() throws {
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let draft = DatabaseConnectionDraft(
            displayName: "TUF MongoDB",
            product: .mongoDB,
            username: "edith",
            database: "million_rows",
            authenticationDatabase: "admin",
            passwordReference: reference)

        let definition = try draft.definition()

        #expect(definition.authentication.kind == .scram)
        #expect(definition.authentication.source == "admin")
    }

    @Test("SQLite uses its path and no credentials")
    func sqlite() throws {
        let draft = DatabaseConnectionDraft(
            displayName: "Local SQLite",
            product: .sqlite,
            path: "/tmp/edith.sqlite")

        let definition = try draft.definition()

        #expect(definition.authentication.kind == .none)
        #expect(
            definition.location
                == .sqlite(
                    DatabaseSQLiteLocation(path: "/tmp/edith.sqlite", accessMode: .readOnly)))
    }

    @Test("Unsupported live products are rejected")
    func unsupportedProduct() {
        let draft = DatabaseConnectionDraft(displayName: "MySQL", product: .mysql)

        #expect(throws: DatabaseConnectionDraftError.unsupportedProduct(.mysql)) {
            try draft.definition()
        }
    }

    @Test("Redis logical database must be canonical and bounded")
    func invalidLogicalDatabase() {
        let draft = DatabaseConnectionDraft(
            displayName: "Redis",
            product: .redis,
            database: "01")

        #expect(throws: DatabaseConnectionDraftError.invalidLogicalDatabase) {
            try draft.definition()
        }
    }
}
