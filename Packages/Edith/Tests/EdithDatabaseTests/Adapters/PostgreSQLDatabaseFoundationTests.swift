import Foundation
import PostgresNIO
import Testing

@testable import EdithDatabase

private struct PostgreSQLDatabaseFoundationUnknownFailure: Error {}

@Test func postgresqlFoundationConnectionPlanBuildsTypedConfiguration() throws {
    let plan = PostgreSQLDatabaseConnectionPlan(
        host: "127.0.0.1",
        port: 55_432,
        username: "reader",
        password: "fixture-password",
        database: "edith_lab",
        tls: .required(verifyCertificate: false),
        tlsServerName: "database.example.test",
        connectTimeoutMilliseconds: 2_000,
        statementTimeoutMilliseconds: 3_000,
        readOnly: true)
    let configuration = try plan.configuration()
    #expect(configuration.host == "127.0.0.1")
    #expect(configuration.port == 55_432)
    #expect(configuration.username == "reader")
    #expect(configuration.password == "fixture-password")
    #expect(configuration.database == "edith_lab")
    #expect(configuration.tls.isAllowed)
    #expect(configuration.tls.isEnforced)
    #expect(configuration.options.connectTimeout == .milliseconds(2_000))
    #expect(configuration.options.tlsServerName == "database.example.test")
    #expect(
        configuration.options.additionalStartupParameters.map(\.0)
            == ["application_name", "statement_timeout", "default_transaction_read_only"])
    #expect(
        configuration.options.additionalStartupParameters.map(\.1)
            == ["Edith", "3000", "on"])
}

@Test func postgresqlFoundationIdentityMapsStandaloneServer() throws {
    let identity = try PostgreSQLDatabaseDriverSupport.identity(
        PostgreSQLDatabaseIdentityValues(
            version: "17.11 (Debian 17.11-1.pgdg12+2)",
            versionNumber: 170_011,
            database: "edith_lab",
            serverEncoding: "UTF8",
            inRecovery: false,
            replicaCount: 0))
    #expect(identity.product == .postgresql)
    #expect(identity.version?.major == 17)
    #expect(identity.version?.minor == 11)
    #expect(identity.version?.patch == nil)
    #expect(identity.distribution == "PostgreSQL")
    #expect(identity.topology.kind == .standalone)
    #expect(identity.topology.localRole == "primary")
    #expect(identity.topology.nodeCount == 1)
    #expect(identity.topology.replicaCount == nil)
    #expect(
        identity.topology.attributes
            == [
                DatabaseStringAttribute(name: "database", value: "edith_lab"),
                DatabaseStringAttribute(name: "serverEncoding", value: "UTF8"),
                DatabaseStringAttribute(name: "serverVersionNumber", value: "170011"),
            ])
}

@Test func postgresqlFoundationIdentityMapsReplicationWithoutInventingStandbyCount() throws {
    let primary = try PostgreSQLDatabaseDriverSupport.identity(
        PostgreSQLDatabaseIdentityValues(
            version: "16.4",
            versionNumber: 160_004,
            database: "app",
            serverEncoding: "UTF8",
            inRecovery: false,
            replicaCount: 2))
    #expect(primary.topology.kind == .primaryReplica)
    #expect(primary.topology.localRole == "primary")
    #expect(primary.topology.nodeCount == 3)
    #expect(primary.topology.replicaCount == 2)
    let standby = try PostgreSQLDatabaseDriverSupport.identity(
        PostgreSQLDatabaseIdentityValues(
            version: "16.4",
            versionNumber: 160_004,
            database: "app",
            serverEncoding: "UTF8",
            inRecovery: true,
            replicaCount: 0))
    #expect(standby.topology.kind == .primaryReplica)
    #expect(standby.topology.localRole == "standby")
    #expect(standby.topology.nodeCount == nil)
    #expect(standby.topology.replicaCount == nil)
}

@Test func postgresqlFoundationIdentityRejectsUnboundedOrInvalidValues() {
    #expect(throws: PostgreSQLDatabaseDriverFailure.self) {
        _ = try PostgreSQLDatabaseDriverSupport.identity(
            PostgreSQLDatabaseIdentityValues(
                version: String(repeating: "1", count: 257),
                versionNumber: 170_011,
                database: "edith_lab",
                serverEncoding: "UTF8",
                inRecovery: false,
                replicaCount: 0))
    }
    #expect(throws: PostgreSQLDatabaseDriverFailure.self) {
        _ = try PostgreSQLDatabaseDriverSupport.identity(
            PostgreSQLDatabaseIdentityValues(
                version: "17.11",
                versionNumber: 170_011,
                database: "edith\0lab",
                serverEncoding: "UTF8",
                inRecovery: false,
                replicaCount: 0))
    }
    #expect(throws: PostgreSQLDatabaseDriverFailure.self) {
        _ = try PostgreSQLDatabaseDriverSupport.identity(
            PostgreSQLDatabaseIdentityValues(
                version: "17.11",
                versionNumber: 170_011,
                database: "edith_lab",
                serverEncoding: "UTF8",
                inRecovery: false,
                replicaCount: 1_000_001))
    }
}

@Test func postgresqlFoundationDriverErrorsRemainTypedAndRedacted() throws {
    #expect(
        PostgreSQLDatabaseDriverErrorClassifier.classify(
            code: .server,
            sqlState: "28P01") == .authentication)
    #expect(
        PostgreSQLDatabaseDriverErrorClassifier.classify(
            code: .server,
            sqlState: "42501") == .permission("42501"))
    #expect(
        PostgreSQLDatabaseDriverErrorClassifier.classify(
            code: .server,
            sqlState: "57014") == .timeout)
    #expect(
        PostgreSQLDatabaseDriverErrorClassifier.classify(
            code: .server,
            sqlState: "08006") == .connection)
    #expect(
        PostgreSQLDatabaseDriverErrorClassifier.classify(
            code: .server,
            sqlState: "XX001") == .server("XX001"))
    #expect(
        PostgreSQLDatabaseDriverErrorClassifier.classify(
            code: .server,
            sqlState: "unsafe detail") == .server(nil))
    #expect(
        try PostgreSQLDatabaseDriverErrorClassifier.classify(
            PostgreSQLDatabaseFoundationUnknownFailure()) == .connection)
    #expect(throws: CancellationError.self) {
        _ = try PostgreSQLDatabaseDriverErrorClassifier.classify(CancellationError())
    }
}

private enum PostgreSQLDatabaseLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_POSTGRESQL_HOST",
        "EDITH_DATABASE_POSTGRESQL_PORT",
        "EDITH_DATABASE_POSTGRESQL_DATABASE",
        "EDITH_DATABASE_POSTGRESQL_USERNAME",
        "EDITH_DATABASE_POSTGRESQL_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }
}

@Test(.enabled(if: PostgreSQLDatabaseLiveEnvironment.isEnabled))
func postgresqlFoundationLiveAuthenticatedIdentity() async throws {
    let environment = PostgreSQLDatabaseLiveEnvironment.values
    let host = try #require(environment["EDITH_DATABASE_POSTGRESQL_HOST"])
    let portText = try #require(environment["EDITH_DATABASE_POSTGRESQL_PORT"])
    let port = try #require(Int(portText))
    let database = try #require(environment["EDITH_DATABASE_POSTGRESQL_DATABASE"])
    let username = try #require(environment["EDITH_DATABASE_POSTGRESQL_USERNAME"])
    let password = try #require(environment["EDITH_DATABASE_POSTGRESQL_PASSWORD"])
    let client = try await PostgresNIODatabaseClient.connect(
        PostgreSQLDatabaseConnectionPlan(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disabled,
            tlsServerName: nil,
            connectTimeoutMilliseconds: 5_000,
            statementTimeoutMilliseconds: 5_000,
            readOnly: true))
    let identity: DatabaseProductIdentity
    do {
        identity = try await client.discoverIdentity()
    } catch {
        await client.disconnect()
        throw error
    }
    await client.disconnect()
    #expect(identity.product == .postgresql)
    #expect(identity.version?.major == 17)
    #expect(identity.topology.kind == .standalone)
    #expect(identity.topology.localRole == "primary")
    #expect(
        identity.topology.attributes.contains(
            DatabaseStringAttribute(name: "database", value: database)))
    let version = identity.version?.string ?? "unknown"
    print(
        "postgresql live verified version=\(version) database=\(database)")
}
