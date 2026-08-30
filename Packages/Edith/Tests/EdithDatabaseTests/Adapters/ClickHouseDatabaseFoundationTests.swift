import Foundation
import Testing

@testable import EdithDatabase

@Test func clickHouseFoundationBuildsHTTPAndHTTPSURLs() throws {
    let http = try clickHouseFoundationPlan(
        host: "127.0.0.1",
        tls: .disabled
    ).baseURL()
    #expect(http.absoluteString == "http://127.0.0.1:8123/")
    let https = try clickHouseFoundationPlan(
        host: "db.example.test",
        tls: .required
    ).baseURL()
    #expect(https.absoluteString == "https://db.example.test:8123/")
    let ipv6 = try clickHouseFoundationPlan(
        host: "[::1]",
        tls: .disabled
    ).baseURL()
    #expect(ipv6.absoluteString == "http://[::1]:8123/")
}

@Test func clickHouseFoundationRejectsInvalidEndpoints() {
    #expect(throws: ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration) {
        _ = try clickHouseFoundationPlan(
            host: "bad host",
            tls: .disabled
        ).baseURL()
    }
    #expect(throws: ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration) {
        _ = try ClickHouseDatabaseConnectionPlan(
            host: "127.0.0.1",
            port: 0,
            username: "reader",
            password: nil,
            database: "default",
            tls: .disabled,
            requestTimeoutMilliseconds: 2_000,
            readOnly: true
        ).baseURL()
    }
}

@Test func clickHouseFoundationDecodesStandaloneIdentity() async throws {
    let values = ClickHouseDatabaseIdentityValues(
        version: "26.7.5.10",
        database: "edith_scale",
        timezone: "UTC",
        hostName: "clickhouse-node-1",
        clusterName: "",
        clusterNodeCount: 0,
        shardCount: 0,
        totalReplicas: 0)
    let body = try JSONEncoder().encode(values)
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(statusCode: 200, headers: [:], body: body)
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let client = URLSessionClickHouseDatabaseClient(transport: transport)
    let identity = try await client.discoverIdentity()
    await client.disconnect()
    #expect(identity.product == .clickHouse)
    #expect(identity.version?.string == "26.7.5.10")
    #expect(identity.version?.major == 26)
    #expect(identity.version?.minor == 7)
    #expect(identity.version?.patch == 5)
    #expect(identity.distribution == "ClickHouse")
    #expect(identity.topology.kind == .standalone)
    #expect(identity.topology.localRole == "node")
    #expect(identity.topology.nodeCount == 1)
    #expect(identity.serverIdentifier == "clickhouse-node-1")
    #expect(
        identity.topology.attributes
            == [
                DatabaseStringAttribute(name: "database", value: "edith_scale"),
                DatabaseStringAttribute(name: "hostName", value: "clickhouse-node-1"),
                DatabaseStringAttribute(name: "interface", value: "http"),
                DatabaseStringAttribute(name: "timezone", value: "UTC"),
                DatabaseStringAttribute(name: "totalReplicas", value: "0"),
            ])
}

@Test func clickHouseFoundationMapsDistributedTopology() throws {
    let identity = try ClickHouseDatabaseDriverSupport.identity(
        ClickHouseDatabaseIdentityValues(
            version: "25.8.4.13",
            database: "analytics",
            timezone: "Europe/London",
            hostName: "node-2",
            clusterName: "analytics_cluster",
            clusterNodeCount: 6,
            shardCount: 3,
            totalReplicas: 2))
    #expect(identity.topology.kind == .distributed)
    #expect(identity.topology.name == "analytics_cluster")
    #expect(identity.topology.localRole == "replica")
    #expect(identity.topology.nodeCount == 6)
    #expect(identity.topology.replicaCount == 1)
    #expect(identity.topology.shardCount == 3)
}

@Test func clickHouseFoundationRejectsInvalidIdentityValues() {
    #expect(throws: ClickHouseDatabaseDriverFailure.decoding) {
        _ = try ClickHouseDatabaseDriverSupport.identity(
            ClickHouseDatabaseIdentityValues(
                version: String(repeating: "1", count: 257),
                database: "analytics",
                timezone: "UTC",
                hostName: "node-1",
                clusterName: "",
                clusterNodeCount: 0,
                shardCount: 0,
                totalReplicas: 0))
    }
    #expect(throws: ClickHouseDatabaseDriverFailure.decoding) {
        _ = try ClickHouseDatabaseDriverSupport.identity(
            ClickHouseDatabaseIdentityValues(
                version: "26.7.5.10",
                database: "analytics\0archive",
                timezone: "UTC",
                hostName: "node-1",
                clusterName: "",
                clusterNodeCount: 0,
                shardCount: 0,
                totalReplicas: 0))
    }
    #expect(throws: ClickHouseDatabaseDriverFailure.decoding) {
        _ = try ClickHouseDatabaseDriverSupport.identity(
            ClickHouseDatabaseIdentityValues(
                version: "26.7.5.10",
                database: "analytics",
                timezone: "UTC",
                hostName: "node-1",
                clusterName: "cluster",
                clusterNodeCount: 0,
                shardCount: 0,
                totalReplicas: 0))
    }
    #expect(throws: ClickHouseDatabaseDriverFailure.decoding) {
        _ = try ClickHouseDatabaseDriverSupport.identity(
            ClickHouseDatabaseIdentityValues(
                version: "26.7.5.10",
                database: "analytics",
                timezone: "UTC",
                hostName: "node-1",
                clusterName: "cluster",
                clusterNodeCount: 2,
                shardCount: 3,
                totalReplicas: 1_000_001))
    }
}

@Test func clickHouseFoundationDriverErrorsRemainTypedAndRedacted() throws {
    #expect(
        try ClickHouseDatabaseDriverErrorClassifier.classify(
            statusCode: 403,
            exceptionCode: "516") == .authentication)
    #expect(
        try ClickHouseDatabaseDriverErrorClassifier.classify(
            statusCode: 403,
            exceptionCode: "497") == .permission("497"))
    #expect(
        try ClickHouseDatabaseDriverErrorClassifier.classify(
            statusCode: 500,
            exceptionCode: "159") == .timeout)
    #expect(
        try ClickHouseDatabaseDriverErrorClassifier.classify(
            statusCode: 500,
            exceptionCode: "241") == .resourceLimit("241"))
    #expect(
        try ClickHouseDatabaseDriverErrorClassifier.classify(
            statusCode: 500,
            exceptionCode: nil) == .server(nil))
    #expect(
        try ClickHouseDatabaseDriverErrorClassifier.classify(
            ClickHouseDatabaseHTTPTransportFailure.responseTooLarge)
            == .resourceLimit(nil))
    #expect(
        ClickHouseDatabaseDriverErrorClassifier.classify(URLError.timedOut) == .timeout)
    #expect(
        ClickHouseDatabaseDriverErrorClassifier.classify(
            URLError.serverCertificateUntrusted) == .tls)
    #expect(throws: CancellationError.self) {
        _ = try ClickHouseDatabaseDriverErrorClassifier.classify(
            statusCode: 500,
            exceptionCode: "394")
    }
}

@Test func clickHouseFoundationMapsAuthenticationWithoutReturningServerBody() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(
            statusCode: 403,
            headers: ["X-ClickHouse-Exception-Code": "516"],
            body: Data("credential detail that must not escape".utf8))
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let client = URLSessionClickHouseDatabaseClient(transport: transport)
    await #expect(throws: ClickHouseDatabaseDriverFailure.authentication) {
        _ = try await client.discoverIdentity()
    }
    await client.disconnect()
}

@Test func clickHouseFoundationRejectsMalformedIdentityResponses() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(
            statusCode: 200,
            headers: [:],
            body: Data("not-json".utf8))
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let client = URLSessionClickHouseDatabaseClient(transport: transport)
    await #expect(throws: ClickHouseDatabaseDriverFailure.decoding) {
        _ = try await client.discoverIdentity()
    }
    await client.disconnect()
}

@Test func clickHouseFoundationRejectsUseAfterDisconnect() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(statusCode: 200, headers: [:], body: Data())
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let client = URLSessionClickHouseDatabaseClient(transport: transport)
    await client.disconnect()
    await #expect(throws: ClickHouseDatabaseDriverFailure.connection) {
        _ = try await client.discoverIdentity()
    }
}

private func clickHouseFoundationPlan(
    host: String,
    tls: ClickHouseDatabaseTLSPlan
) -> ClickHouseDatabaseConnectionPlan {
    ClickHouseDatabaseConnectionPlan(
        host: host,
        port: 8_123,
        username: "reader",
        password: "fixture-password",
        database: "edith_lab",
        tls: tls,
        requestTimeoutMilliseconds: 2_000,
        readOnly: true)
}

private enum ClickHouseDatabaseLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_CLICKHOUSE_HOST",
        "EDITH_DATABASE_CLICKHOUSE_PORT",
        "EDITH_DATABASE_CLICKHOUSE_DATABASE",
        "EDITH_DATABASE_CLICKHOUSE_USERNAME",
        "EDITH_DATABASE_CLICKHOUSE_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }

    static func plan(
        timeoutMilliseconds: UInt64 = 5_000,
        passwordOverride: String? = nil
    ) throws -> ClickHouseDatabaseConnectionPlan {
        let host = try #require(values["EDITH_DATABASE_CLICKHOUSE_HOST"])
        let portText = try #require(values["EDITH_DATABASE_CLICKHOUSE_PORT"])
        let port = try #require(Int(portText))
        let database = try #require(values["EDITH_DATABASE_CLICKHOUSE_DATABASE"])
        let username = try #require(values["EDITH_DATABASE_CLICKHOUSE_USERNAME"])
        let password = try #require(values["EDITH_DATABASE_CLICKHOUSE_PASSWORD"])
        return ClickHouseDatabaseConnectionPlan(
            host: host,
            port: port,
            username: username,
            password: passwordOverride ?? password,
            database: database,
            tls: .disabled,
            requestTimeoutMilliseconds: timeoutMilliseconds,
            readOnly: true)
    }
}

@Test(.enabled(if: ClickHouseDatabaseLiveEnvironment.isEnabled))
func clickHouseFoundationLiveAuthenticatedIdentity() async throws {
    let plan = try ClickHouseDatabaseLiveEnvironment.plan()
    let client = try await URLSessionClickHouseDatabaseClient.connect(plan)
    let identity: DatabaseProductIdentity
    do {
        identity = try await client.discoverIdentity()
    } catch {
        await client.disconnect()
        throw error
    }
    await client.disconnect()
    #expect(identity.product == .clickHouse)
    #expect(identity.version?.major == 26)
    #expect(identity.topology.kind == .standalone)
    #expect(identity.topology.localRole == "node")
    #expect(
        identity.topology.attributes.contains(
            DatabaseStringAttribute(
                name: "database",
                value: plan.database ?? "")))
    print(
        "clickhouse live verified version=\(identity.version?.string ?? "unknown") database=\(plan.database ?? "unknown")"
    )
}

@Test(.enabled(if: ClickHouseDatabaseLiveEnvironment.isEnabled))
func clickHouseFoundationLiveRepeatedConnectionLifecycle() async throws {
    let plan = try ClickHouseDatabaseLiveEnvironment.plan()
    for _ in 0..<4 {
        let client = try await URLSessionClickHouseDatabaseClient.connect(plan)
        _ = try await client.discoverIdentity()
        await client.disconnect()
        await #expect(throws: ClickHouseDatabaseDriverFailure.connection) {
            _ = try await client.discoverIdentity()
        }
    }
}

@Test(.enabled(if: ClickHouseDatabaseLiveEnvironment.isEnabled))
func clickHouseFoundationLiveRejectsInvalidAuthentication() async throws {
    let values = ClickHouseDatabaseLiveEnvironment.values
    let password = try #require(values["EDITH_DATABASE_CLICKHOUSE_PASSWORD"])
    let plan = try ClickHouseDatabaseLiveEnvironment.plan(
        passwordOverride: password + "-invalid")
    let client = try await URLSessionClickHouseDatabaseClient.connect(plan)
    await #expect(throws: ClickHouseDatabaseDriverFailure.authentication) {
        _ = try await client.discoverIdentity()
    }
    await client.disconnect()
}

@Test(.enabled(if: ClickHouseDatabaseLiveEnvironment.isEnabled))
func clickHouseFoundationLiveCancellationLeavesTransportReusable() async throws {
    let plan = try ClickHouseDatabaseLiveEnvironment.plan(
        timeoutMilliseconds: 10_000)
    let transport = try ClickHouseDatabaseHTTPTransport(plan: plan)
    let query = Task {
        try await transport.execute(
            query: "SELECT sleep(2) FORMAT JSONEachRow",
            maximumResponseBytes: 4_096)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let startedAt = ContinuousClock.now
    query.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await query.value
    }
    #expect(ContinuousClock.now - startedAt < .seconds(2))
    let response = try await transport.execute(
        query: "SELECT 1 AS value FORMAT JSONEachRow",
        maximumResponseBytes: 4_096)
    #expect(response.body == Data("{\"value\":1}\n".utf8))
    await transport.close()
}

@Test(.enabled(if: ClickHouseDatabaseLiveEnvironment.isEnabled))
func clickHouseFoundationLiveTimeoutLeavesTransportReusable() async throws {
    let plan = try ClickHouseDatabaseLiveEnvironment.plan(
        timeoutMilliseconds: 200)
    let transport = try ClickHouseDatabaseHTTPTransport(plan: plan)
    let startedAt = ContinuousClock.now
    do {
        _ = try await transport.execute(
            query: "SELECT sleep(2) FORMAT JSONEachRow",
            maximumResponseBytes: 4_096)
        Issue.record("expected timeout")
    } catch let error as URLError {
        #expect(error.code == .timedOut)
        #expect(ClickHouseDatabaseDriverErrorClassifier.classify(error.code) == .timeout)
    } catch {
        Issue.record("unexpected timeout failure type")
    }
    #expect(ContinuousClock.now - startedAt < .seconds(2))
    let response = try await transport.execute(
        query: "SELECT 1 AS value FORMAT JSONEachRow",
        maximumResponseBytes: 4_096)
    #expect(response.body == Data("{\"value\":1}\n".utf8))
    await transport.close()
}

@Test(.enabled(if: ClickHouseDatabaseLiveEnvironment.isEnabled))
func clickHouseFoundationLiveEnforcesResponseBounds() async throws {
    let plan = try ClickHouseDatabaseLiveEnvironment.plan()
    let transport = try ClickHouseDatabaseHTTPTransport(plan: plan)
    await #expect(throws: ClickHouseDatabaseHTTPTransportFailure.responseTooLarge) {
        _ = try await transport.execute(
            query: "SELECT repeat('x', 1000000) AS value FORMAT JSONEachRow",
            maximumResponseBytes: 4_096)
    }
    await transport.close()
}
