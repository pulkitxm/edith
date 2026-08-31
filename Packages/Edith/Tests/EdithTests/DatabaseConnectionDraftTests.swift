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

    @Test("Elasticsearch supports anonymous HTTP connections")
    func elasticsearchAnonymous() throws {
        let draft = DatabaseConnectionDraft(
            displayName: "TUF Elasticsearch",
            product: .elasticsearch,
            host: "127.0.0.1",
            port: 59_200,
            environmentKind: .testing,
            environmentLabel: "TUF",
            environmentProtection: .standard,
            readOnlyPolicy: .disabled,
            productionPolicy: .standard)

        let definition = try draft.definition()

        #expect(definition.productHint == .elasticsearch)
        #expect(definition.authentication.kind == .none)
        guard case .network(let endpoints) = definition.location else {
            Issue.record("Expected a network connection.")
            return
        }
        #expect(endpoints.first?.host == "127.0.0.1")
        #expect(endpoints.first?.port.value == 59_200)
        #expect(definition.namespaces.database == nil)
        #expect(definition.readOnlyPolicy == .disabled)
        #expect(definition.environment.kind == .testing)
    }

    @Test("Elasticsearch supports basic authentication and verified TLS")
    func elasticsearchAuthenticationAndTLS() throws {
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let draft = DatabaseConnectionDraft(
            displayName: "Elastic Cloud",
            product: .elasticsearch,
            host: "search.example.com",
            username: "edith",
            passwordReference: reference,
            tlsMode: .required)

        let definition = try draft.definition()

        #expect(definition.authentication.kind == .usernameAndPassword)
        #expect(definition.authentication.secretReferences == [reference])
        #expect(definition.tls.mode == .required)
        #expect(definition.tls.verification == .full)
    }

    @Test("OpenSearch supports anonymous and authenticated connections")
    func openSearchConnections() throws {
        let anonymous = try DatabaseConnectionDraft(
            displayName: "TUF OpenSearch",
            product: .openSearch,
            host: "127.0.0.1",
            port: 59_201,
            environmentKind: .testing,
            environmentLabel: "TUF",
            environmentProtection: .standard,
            readOnlyPolicy: .disabled,
            productionPolicy: .standard
        ).definition()
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let authenticated = try DatabaseConnectionDraft(
            displayName: "OpenSearch Cloud",
            product: .openSearch,
            host: "search.example.com",
            username: "edith",
            passwordReference: reference,
            tlsMode: .required
        ).definition()

        #expect(anonymous.productHint == .openSearch)
        #expect(anonymous.authentication.kind == .none)
        #expect(anonymous.tls.mode == .disabled)
        #expect(authenticated.authentication.kind == .usernameAndPassword)
        #expect(authenticated.authentication.secretReferences == [reference])
        #expect(authenticated.tls.mode == .required)
        #expect(authenticated.tls.verification == .full)
    }

    @Test("ClickHouse requires a username and supports authenticated TLS")
    func clickHouseConnections() throws {
        let anonymous = try DatabaseConnectionDraft(
            displayName: "TUF ClickHouse",
            product: .clickHouse,
            host: "127.0.0.1",
            port: 58_123,
            username: "default",
            database: "analytics"
        ).definition()
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let authenticated = try DatabaseConnectionDraft(
            displayName: "ClickHouse Cloud",
            product: .clickHouse,
            host: "analytics.example.com",
            username: "edith",
            database: "warehouse",
            passwordReference: reference,
            tlsMode: .required
        ).definition()

        #expect(anonymous.productHint == .clickHouse)
        #expect(anonymous.username == "default")
        #expect(anonymous.authentication.kind == .none)
        #expect(anonymous.namespaces.database == "analytics")
        #expect(authenticated.authentication.kind == .usernameAndPassword)
        #expect(authenticated.authentication.secretReferences == [reference])
        #expect(authenticated.tls.mode == .required)
        #expect(authenticated.tls.verification == .full)
    }

    @Test("ClickHouse rejects a missing username")
    func clickHouseMissingUsername() {
        let draft = DatabaseConnectionDraft(
            displayName: "ClickHouse",
            product: .clickHouse)

        #expect(throws: DatabaseConnectionDraftError.missingUsername) {
            try draft.definition()
        }
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

    @Test("MySQL connections retain their database and TLS policy")
    func mysql() throws {
        let draft = DatabaseConnectionDraft(
            displayName: "MySQL",
            product: .mysql,
            username: "edith",
            database: "app",
            tlsMode: .required)

        let definition = try draft.definition()

        #expect(definition.productHint == .mysql)
        #expect(definition.namespaces.database == "app")
        #expect(definition.authentication.kind == .none)
        #expect(definition.tls.mode == .required)
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
