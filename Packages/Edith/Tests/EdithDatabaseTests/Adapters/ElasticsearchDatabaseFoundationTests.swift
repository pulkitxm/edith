import Foundation
import Testing

@testable import EdithDatabase

private struct ElasticsearchDatabaseFoundationUnknownFailure: Error {}

private enum ElasticsearchDatabaseFoundationScenario: Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case redirect(status: Int, target: URL)
    case stalled
}

private struct ElasticsearchDatabaseFoundationRequestSnapshot: Sendable {
    let url: String
    let authorization: String?
    let accept: String?
    let opaqueIdentifier: String?
}

private final class ElasticsearchDatabaseFoundationStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [ElasticsearchDatabaseFoundationScenario] = []
    private var requests: [ElasticsearchDatabaseFoundationRequestSnapshot] = []
    private var stoppedRequestCount = 0

    func configure(_ scenarios: [ElasticsearchDatabaseFoundationScenario]) {
        lock.withLock {
            self.scenarios = scenarios
            requests = []
            stoppedRequestCount = 0
        }
    }

    func take(
        _ request: URLRequest
    ) -> ElasticsearchDatabaseFoundationScenario? {
        lock.withLock {
            requests.append(
                ElasticsearchDatabaseFoundationRequestSnapshot(
                    url: request.url?.absoluteString ?? "",
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    accept: request.value(forHTTPHeaderField: "Accept"),
                    opaqueIdentifier: request.value(forHTTPHeaderField: "X-Opaque-Id")))
            guard !scenarios.isEmpty else { return nil }
            return scenarios.removeFirst()
        }
    }

    func recordStop() {
        lock.withLock {
            stoppedRequestCount += 1
        }
    }

    func snapshot() -> (
        requests: [ElasticsearchDatabaseFoundationRequestSnapshot],
        stoppedRequestCount: Int
    ) {
        lock.withLock {
            (requests, stoppedRequestCount)
        }
    }
}

private final class ElasticsearchDatabaseFoundationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ElasticsearchDatabaseFoundationStubState()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let scenario = Self.state.take(request) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse))
            return
        }
        switch scenario {
        case let .response(status, headers, body):
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers)
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(status, target):
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString])
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.badServerResponse))
                return
            }
            var redirectedRequest = request
            redirectedRequest.url = target
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirectedRequest,
                redirectResponse: response)
        case .stalled:
            return
        }
    }

    override func stopLoading() {
        Self.state.recordStop()
    }
}

private func elasticsearchFoundationSession(
    _ plan: ElasticsearchDatabaseConnectionPlan
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ElasticsearchDatabaseFoundationURLProtocol.self]
    configuration.timeoutIntervalForRequest =
        TimeInterval(plan.connectTimeoutMilliseconds) / 1_000
    configuration.timeoutIntervalForResource =
        TimeInterval(plan.requestTimeoutMilliseconds) / 1_000
    configuration.urlCache = nil
    return URLSession(
        configuration: configuration,
        delegate: ElasticsearchDatabaseURLSessionDelegate(),
        delegateQueue: nil)
}

private func elasticsearchFoundationPlan(
    endpoint: String = "https://search.example.test/base",
    authorization: ElasticsearchDatabaseAuthorization = .basic(
        username: "reader",
        password: "fixture-password"),
    connectTimeoutMilliseconds: UInt64 = 2_000,
    requestTimeoutMilliseconds: UInt64 = 3_000,
    maximumResponseBytes: Int = 1_048_576
) throws -> ElasticsearchDatabaseConnectionPlan {
    ElasticsearchDatabaseConnectionPlan(
        endpoint: try #require(URL(string: endpoint)),
        authorization: authorization,
        connectTimeoutMilliseconds: connectTimeoutMilliseconds,
        requestTimeoutMilliseconds: requestTimeoutMilliseconds,
        maximumResponseBytes: maximumResponseBytes)
}

private let elasticsearchFoundationRootBody = Data(
    """
    {
      "name": "node-a",
      "cluster_name": "edith-search",
      "cluster_uuid": "cluster-identifier",
      "version": {
        "number": "9.5.2",
        "build_flavor": "default",
        "build_type": "docker",
        "build_hash": "abcdef123456"
      },
      "tagline": "You Know, for Search"
    }
    """.utf8)

private let elasticsearchFoundationNodesBody = Data(
    """
    {
      "_nodes": {"total": 1, "successful": 1, "failed": 0},
      "cluster_name": "edith-search",
      "nodes": {
        "node-id-a": {
          "name": "node-a",
          "version": "9.5.2",
          "roles": ["data", "ingest", "master"],
          "plugins": [{"name": "analysis-icu", "version": "9.5.2"}],
          "modules": [{"name": "lang-painless", "version": "9.5.2"}]
        }
      }
    }
    """.utf8)

private var elasticsearchFoundationSuccessScenarios: [ElasticsearchDatabaseFoundationScenario] {
    [
        .response(
            status: 200,
            headers: [
                "Content-Type": "application/json",
                "X-Elastic-Product": "Elasticsearch",
            ],
            body: elasticsearchFoundationRootBody),
        .response(
            status: 200,
            headers: [
                "Content-Type": "application/json",
                "X-Elastic-Product": "Elasticsearch",
            ],
            body: elasticsearchFoundationNodesBody),
    ]
}

@Suite(.serialized)
struct ElasticsearchDatabaseFoundationTransportTests {
    @Test func connectsWithBoundedAuthenticatedRequests() async throws {
        ElasticsearchDatabaseFoundationURLProtocol.state.configure(
            elasticsearchFoundationSuccessScenarios)
        let plan = try elasticsearchFoundationPlan()
        let client = try await URLSessionElasticsearchDatabaseClient.connect(
            plan,
            sessionFactory: { elasticsearchFoundationSession($0) })
        let identity = try await client.discoverIdentity()
        await client.disconnect()

        #expect(identity.product == .elasticsearch)
        #expect(identity.version?.string == "9.5.2")
        #expect(identity.version?.major == 9)
        #expect(identity.version?.minor == 5)
        #expect(identity.version?.patch == 2)
        #expect(identity.distribution == "Elasticsearch")
        #expect(identity.serverIdentifier == "cluster-identifier")
        #expect(identity.topology.kind == .standalone)
        #expect(identity.topology.name == "edith-search")
        #expect(identity.topology.localRole == "master-eligible")
        #expect(identity.topology.nodeCount == 1)
        #expect(
            identity.modules
                == [DatabaseExtensionIdentity(name: "lang-painless", version: "9.5.2")])
        #expect(
            identity.plugins
                == [DatabaseExtensionIdentity(name: "analysis-icu", version: "9.5.2")])

        let snapshot = ElasticsearchDatabaseFoundationURLProtocol.state.snapshot()
        #expect(snapshot.requests.count == 2)
        let expectedAuthorization = ElasticsearchDatabaseAuthorization.basic(
            username: "reader",
            password: "fixture-password"
        ).headerValue
        #expect(snapshot.requests.allSatisfy { $0.authorization == expectedAuthorization })
        #expect(snapshot.requests.allSatisfy { $0.accept == "application/json" })
        #expect(snapshot.requests.allSatisfy { $0.opaqueIdentifier == "edith-database" })
        #expect(snapshot.requests[0].url == "https://search.example.test/base/")
        #expect(snapshot.requests[1].url.contains("/base/_nodes/_all/plugins?"))
        #expect(snapshot.requests[1].url.contains("filter_path="))
    }

    @Test func rejectsUnexpectedProductsBeforeTopologyDiscovery() async throws {
        ElasticsearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-Elastic-Product": "OpenSearch",
                ],
                body: elasticsearchFoundationRootBody)
        ])
        let plan = try elasticsearchFoundationPlan()
        await #expect(throws: ElasticsearchDatabaseDriverFailure.unsupportedProduct) {
            _ = try await URLSessionElasticsearchDatabaseClient.connect(
                plan,
                sessionFactory: { elasticsearchFoundationSession($0) })
        }
        #expect(
            ElasticsearchDatabaseFoundationURLProtocol.state.snapshot().requests.count == 1)
    }

    @Test func mapsAuthenticationWithoutRetainingServerDetails() async throws {
        ElasticsearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    """
                    {"error":{"reason":"credential detail must stay private"}}
                    """.utf8))
        ])
        let plan = try elasticsearchFoundationPlan()
        await #expect(throws: ElasticsearchDatabaseDriverFailure.authentication) {
            _ = try await URLSessionElasticsearchDatabaseClient.connect(
                plan,
                sessionFactory: { elasticsearchFoundationSession($0) })
        }
    }

    @Test func rejectsResponsesAboveTheConfiguredBound() async throws {
        let oversized = Data(repeating: 65, count: 2_048)
        ElasticsearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": String(oversized.count),
                    "X-Elastic-Product": "Elasticsearch",
                ],
                body: oversized)
        ])
        let plan = try elasticsearchFoundationPlan(maximumResponseBytes: 1_024)
        await #expect(throws: ElasticsearchDatabaseDriverFailure.responseTooLarge) {
            _ = try await URLSessionElasticsearchDatabaseClient.connect(
                plan,
                sessionFactory: { elasticsearchFoundationSession($0) })
        }
    }

    @Test func rejectsRedirectsWithoutReplayingCredentials() async throws {
        for target in [
            "https://search.example.test/redirected",
            "https://redirect-target.example.test/capture",
        ] {
            let targetURL = try #require(URL(string: target))
            ElasticsearchDatabaseFoundationURLProtocol.state.configure([
                .redirect(status: 307, target: targetURL),
                .response(
                    status: 200,
                    headers: ["X-Elastic-Product": "Elasticsearch"],
                    body: elasticsearchFoundationRootBody),
            ])
            let plan = try elasticsearchFoundationPlan()
            await #expect(throws: ElasticsearchDatabaseDriverFailure.connection) {
                _ = try await URLSessionElasticsearchDatabaseClient.connect(
                    plan,
                    sessionFactory: { elasticsearchFoundationSession($0) })
            }
            let requests = ElasticsearchDatabaseFoundationURLProtocol.state.snapshot().requests
            #expect(requests.count == 1)
            #expect(requests[0].url == "https://search.example.test/base/")
            #expect(requests[0].authorization == plan.authorization.headerValue)
            #expect(requests.allSatisfy { !$0.url.contains("redirect") })
        }
    }

    @Test func cancelsStalledConnectionsPromptly() async throws {
        ElasticsearchDatabaseFoundationURLProtocol.state.configure([.stalled])
        let plan = try elasticsearchFoundationPlan(
            connectTimeoutMilliseconds: 5_000,
            requestTimeoutMilliseconds: 5_000)
        let startedAt = ContinuousClock.now
        let task = Task {
            try await URLSessionElasticsearchDatabaseClient.connect(
                plan,
                sessionFactory: { elasticsearchFoundationSession($0) })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
        try await waitForElasticsearchFoundationStop()
    }

    @Test func timesOutStalledConnectionsPromptly() async throws {
        ElasticsearchDatabaseFoundationURLProtocol.state.configure([.stalled])
        let plan = try elasticsearchFoundationPlan(
            connectTimeoutMilliseconds: 150,
            requestTimeoutMilliseconds: 5_000)
        let startedAt = ContinuousClock.now
        await #expect(throws: ElasticsearchDatabaseDriverFailure.timeout) {
            _ = try await URLSessionElasticsearchDatabaseClient.connect(
                plan,
                sessionFactory: { elasticsearchFoundationSession($0) })
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
        try await waitForElasticsearchFoundationStop()
    }

    @Test func disconnectedClientsCannotReuseIdentity() async throws {
        ElasticsearchDatabaseFoundationURLProtocol.state.configure(
            elasticsearchFoundationSuccessScenarios)
        let client = try await URLSessionElasticsearchDatabaseClient.connect(
            elasticsearchFoundationPlan(),
            sessionFactory: { elasticsearchFoundationSession($0) })
        _ = try await client.discoverIdentity()
        await client.disconnect()
        await #expect(throws: ElasticsearchDatabaseDriverFailure.connection) {
            _ = try await client.discoverIdentity()
        }
    }
}

private func waitForElasticsearchFoundationStop() async throws {
    for _ in 0..<50 {
        if ElasticsearchDatabaseFoundationURLProtocol.state.snapshot().stoppedRequestCount > 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("stalled URL request was not cancelled")
}

@Test func elasticsearchFoundationAuthorizationValuesAreTypedAndValidated() throws {
    #expect(ElasticsearchDatabaseAuthorization.none.headerValue == nil)
    #expect(
        ElasticsearchDatabaseAuthorization.bearer(token: "fixture-token").headerValue
            == "Bearer fixture-token")
    #expect(
        ElasticsearchDatabaseAuthorization.apiKey(
            identifier: "fixture-id",
            secret: "fixture-secret"
        ).headerValue?.hasPrefix("ApiKey ") == true)
    #expect(throws: ElasticsearchDatabaseDriverFailure.invalidConfiguration) {
        try ElasticsearchDatabaseAuthorization.basic(
            username: "invalid:name",
            password: "fixture-password"
        ).validate()
    }
    #expect(throws: ElasticsearchDatabaseDriverFailure.invalidConfiguration) {
        try ElasticsearchDatabaseAuthorization.bearer(token: "unsafe\nvalue").validate()
    }
    #expect(throws: ElasticsearchDatabaseDriverFailure.invalidConfiguration) {
        try ElasticsearchDatabaseAuthorization.apiKey(
            identifier: "",
            secret: "fixture-secret"
        ).validate()
    }
}

@Test func elasticsearchFoundationConnectionPlansRejectUnsafeEndpoints() throws {
    let valid = try elasticsearchFoundationPlan(endpoint: "https://search.example.test:9243/prefix")
    try ElasticsearchDatabaseTransport.validate(valid)
    for endpoint in [
        "ftp://search.example.test",
        "https://reader:fixture-password@search.example.test",
        "https://search.example.test?token=unsafe",
        "https://search.example.test#fragment",
    ] {
        let plan = try elasticsearchFoundationPlan(endpoint: endpoint)
        #expect(throws: ElasticsearchDatabaseDriverFailure.invalidConfiguration) {
            try ElasticsearchDatabaseTransport.validate(plan)
        }
    }
}

@Test func elasticsearchFoundationMapsPartialAndMixedTopology() throws {
    let root = ElasticsearchDatabaseRootResponse(
        name: "node-a",
        clusterName: "edith-search",
        clusterUUID: "cluster-id",
        version: ElasticsearchDatabaseRootResponse.Version(
            number: "9.5.2",
            buildFlavor: "default",
            buildType: "docker",
            buildHash: "abcdef"),
        tagline: "Search")
    let nodes = ElasticsearchDatabaseNodesResponse(
        summary: ElasticsearchDatabaseNodesResponse.Summary(
            total: 3,
            successful: 2,
            failed: 1),
        clusterName: "edith-search",
        nodes: [
            "a": ElasticsearchDatabaseNodesResponse.Node(
                name: "node-a",
                version: "9.5.2",
                roles: ["master", "data_hot"],
                plugins: [
                    ElasticsearchDatabaseNodesResponse.Extension(
                        name: "analysis-icu",
                        version: "9.5.2")
                ],
                modules: []),
            "b": ElasticsearchDatabaseNodesResponse.Node(
                name: "node-b",
                version: "9.4.0",
                roles: ["data_warm"],
                plugins: [
                    ElasticsearchDatabaseNodesResponse.Extension(
                        name: "analysis-icu",
                        version: "9.4.0")
                ],
                modules: []),
        ])
    let identity = try ElasticsearchDatabaseDriverSupport.identity(
        root: root,
        nodes: nodes)
    #expect(identity.topology.kind == .cluster)
    #expect(identity.topology.nodeCount == 3)
    #expect(identity.topology.localRole == "master-eligible")
    #expect(identity.plugins.count == 2)
    #expect(
        identity.compatibilityNotes
            == [
                "Node topology discovery returned partial results.",
                "Cluster nodes report mixed Elasticsearch versions.",
            ])
}

@Test func elasticsearchFoundationRejectsInvalidOrUnboundedIdentity() throws {
    let root = ElasticsearchDatabaseRootResponse(
        name: "node-a",
        clusterName: "edith-search",
        clusterUUID: "cluster-id",
        version: ElasticsearchDatabaseRootResponse.Version(
            number: "9.5.2",
            buildFlavor: "default",
            buildType: "docker",
            buildHash: "abcdef"),
        tagline: "Search")
    let mismatched = ElasticsearchDatabaseNodesResponse(
        summary: ElasticsearchDatabaseNodesResponse.Summary(
            total: 1,
            successful: 1,
            failed: 0),
        clusterName: "another-cluster",
        nodes: [
            "a": ElasticsearchDatabaseNodesResponse.Node(
                name: "node-a",
                version: "9.5.2",
                roles: [],
                plugins: [],
                modules: [])
        ])
    #expect(throws: ElasticsearchDatabaseDriverFailure.invalidResponse) {
        _ = try ElasticsearchDatabaseDriverSupport.identity(root: root, nodes: mismatched)
    }

    let extensions = (0...128).map {
        ElasticsearchDatabaseNodesResponse.Extension(
            name: "plugin-\($0)",
            version: "9.5.2")
    }
    let excessive = ElasticsearchDatabaseNodesResponse(
        summary: ElasticsearchDatabaseNodesResponse.Summary(
            total: 1,
            successful: 1,
            failed: 0),
        clusterName: "edith-search",
        nodes: [
            "a": ElasticsearchDatabaseNodesResponse.Node(
                name: "node-a",
                version: "9.5.2",
                roles: [],
                plugins: extensions,
                modules: [])
        ])
    #expect(throws: ElasticsearchDatabaseDriverFailure.responseTooLarge) {
        _ = try ElasticsearchDatabaseDriverSupport.identity(root: root, nodes: excessive)
    }
}

@Test func elasticsearchFoundationDriverErrorsRemainTypedAndRedacted() throws {
    #expect(
        try ElasticsearchDatabaseDriverErrorClassifier.classify(
            URLError(.timedOut)) == .timeout)
    #expect(
        try ElasticsearchDatabaseDriverErrorClassifier.classify(
            URLError(.serverCertificateUntrusted)) == .tls)
    #expect(
        try ElasticsearchDatabaseDriverErrorClassifier.classify(
            ElasticsearchDatabaseFoundationUnknownFailure()) == .connection)
    #expect(throws: CancellationError.self) {
        _ = try ElasticsearchDatabaseDriverErrorClassifier.classify(CancellationError())
    }
    #expect(throws: ElasticsearchDatabaseDriverFailure.permission(403)) {
        try ElasticsearchDatabaseDriverErrorClassifier.validate(
            ElasticsearchDatabaseHTTPResponse(
                statusCode: 403,
                productHeader: nil,
                body: Data()))
    }
    #expect(throws: ElasticsearchDatabaseDriverFailure.server(500)) {
        try ElasticsearchDatabaseDriverErrorClassifier.validate(
            ElasticsearchDatabaseHTTPResponse(
                statusCode: 999,
                productHeader: nil,
                body: Data()))
    }
}

private enum ElasticsearchDatabaseLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_ELASTICSEARCH_URL",
        "EDITH_DATABASE_ELASTICSEARCH_USERNAME",
        "EDITH_DATABASE_ELASTICSEARCH_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }

    static func plan(
        passwordSuffix: String = ""
    ) throws -> ElasticsearchDatabaseConnectionPlan {
        let endpoint = try #require(values["EDITH_DATABASE_ELASTICSEARCH_URL"])
        let username = try #require(values["EDITH_DATABASE_ELASTICSEARCH_USERNAME"])
        let password = try #require(values["EDITH_DATABASE_ELASTICSEARCH_PASSWORD"])
        return try elasticsearchFoundationPlan(
            endpoint: endpoint,
            authorization: .basic(
                username: username,
                password: password + passwordSuffix),
            connectTimeoutMilliseconds: 5_000,
            requestTimeoutMilliseconds: 5_000,
            maximumResponseBytes: 2_097_152)
    }
}

@Test(.enabled(if: ElasticsearchDatabaseLiveEnvironment.isEnabled))
func elasticsearchFoundationLiveAuthenticatedIdentity() async throws {
    let client = try await URLSessionElasticsearchDatabaseClient.connect(
        ElasticsearchDatabaseLiveEnvironment.plan())
    let identity: DatabaseProductIdentity
    do {
        identity = try await client.discoverIdentity()
    } catch {
        await client.disconnect()
        throw error
    }
    await client.disconnect()
    #expect(identity.product == .elasticsearch)
    #expect(identity.version?.major == 9)
    #expect(identity.topology.kind == .standalone)
    #expect(identity.topology.nodeCount == 1)
    let version = identity.version?.string ?? "unknown"
    let nodeCount = identity.topology.nodeCount ?? 0
    print("elasticsearch live verified version=\(version) nodes=\(nodeCount)")
}

@Test(.enabled(if: ElasticsearchDatabaseLiveEnvironment.isEnabled))
func elasticsearchFoundationLiveRejectsInvalidAuthentication() async throws {
    await #expect(throws: ElasticsearchDatabaseDriverFailure.authentication) {
        _ = try await URLSessionElasticsearchDatabaseClient.connect(
            ElasticsearchDatabaseLiveEnvironment.plan(passwordSuffix: "-invalid"))
    }
}

@Test(.enabled(if: ElasticsearchDatabaseLiveEnvironment.isEnabled))
func elasticsearchFoundationLiveRepeatedConnectionLifecycle() async throws {
    let plan = try ElasticsearchDatabaseLiveEnvironment.plan()
    for _ in 0..<4 {
        let client = try await URLSessionElasticsearchDatabaseClient.connect(plan)
        _ = try await client.discoverIdentity()
        await client.disconnect()
        await #expect(throws: ElasticsearchDatabaseDriverFailure.connection) {
            _ = try await client.discoverIdentity()
        }
    }
}
