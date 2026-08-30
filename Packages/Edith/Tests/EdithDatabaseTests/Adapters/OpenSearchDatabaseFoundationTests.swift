import Foundation
import Testing

@testable import EdithDatabase

private struct OpenSearchDatabaseFoundationUnknownFailure: Error {}

private enum OpenSearchDatabaseFoundationScenario: Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case redirect(status: Int, target: URL)
    case stalled
}

private struct OpenSearchDatabaseFoundationRequestSnapshot: Sendable {
    let url: String
    let authorization: String?
    let accept: String?
    let opaqueIdentifier: String?
}

private final class OpenSearchDatabaseFoundationStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [OpenSearchDatabaseFoundationScenario] = []
    private var requests: [OpenSearchDatabaseFoundationRequestSnapshot] = []
    private var stoppedRequestCount = 0

    func configure(_ scenarios: [OpenSearchDatabaseFoundationScenario]) {
        lock.withLock {
            self.scenarios = scenarios
            requests = []
            stoppedRequestCount = 0
        }
    }

    func take(
        _ request: URLRequest
    ) -> OpenSearchDatabaseFoundationScenario? {
        lock.withLock {
            requests.append(
                OpenSearchDatabaseFoundationRequestSnapshot(
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
        requests: [OpenSearchDatabaseFoundationRequestSnapshot],
        stoppedRequestCount: Int
    ) {
        lock.withLock {
            (requests, stoppedRequestCount)
        }
    }
}

private final class OpenSearchDatabaseFoundationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = OpenSearchDatabaseFoundationStubState()

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

private func openSearchFoundationSession(
    _ plan: OpenSearchDatabaseConnectionPlan
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenSearchDatabaseFoundationURLProtocol.self]
    configuration.timeoutIntervalForRequest =
        TimeInterval(plan.connectTimeoutMilliseconds) / 1_000
    configuration.timeoutIntervalForResource =
        TimeInterval(plan.requestTimeoutMilliseconds) / 1_000
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    return URLSession(
        configuration: configuration,
        delegate: OpenSearchDatabaseURLSessionDelegate(),
        delegateQueue: nil)
}

private func openSearchFoundationPlan(
    endpoint: String = "https://search.example.test/base",
    authorization: OpenSearchDatabaseAuthorization = .basic(
        username: "reader",
        password: "fixture-password"),
    connectTimeoutMilliseconds: UInt64 = 2_000,
    requestTimeoutMilliseconds: UInt64 = 3_000,
    maximumResponseBytes: Int = 1_048_576
) throws -> OpenSearchDatabaseConnectionPlan {
    OpenSearchDatabaseConnectionPlan(
        endpoint: try #require(URL(string: endpoint)),
        authorization: authorization,
        connectTimeoutMilliseconds: connectTimeoutMilliseconds,
        requestTimeoutMilliseconds: requestTimeoutMilliseconds,
        maximumResponseBytes: maximumResponseBytes)
}

private let openSearchFoundationRootBody = Data(
    """
    {
      "name": "node-a",
      "cluster_name": "edith-search",
      "cluster_uuid": "cluster-identifier",
      "version": {
        "distribution": "opensearch",
        "number": "3.8.0",
        "build_type": "tar",
        "build_hash": "abcdef123456",
        "build_date": "2026-08-01T18:48:00.452816924Z",
        "build_snapshot": false,
        "lucene_version": "10.5.0",
        "minimum_wire_compatibility_version": "2.19.0",
        "minimum_index_compatibility_version": "2.0.0"
      },
      "tagline": "The OpenSearch Project: https://opensearch.org/"
    }
    """.utf8)

private let openSearchFoundationNodesBody = Data(
    """
    {
      "_nodes": {"total": 1, "successful": 1, "failed": 0},
      "cluster_name": "edith-search",
      "nodes": {
        "node-id-a": {
          "name": "node-a",
          "version": "3.8.0",
          "roles": ["cluster_manager", "data", "ingest"],
          "plugins": [{"name": "opensearch-security", "version": "3.8.0.0"}],
          "modules": [{"name": "lang-painless", "version": "3.8.0"}]
        }
      }
    }
    """.utf8)

private let openSearchFoundationProductHeaders = [
    "Content-Type": "application/json",
    "X-OpenSearch-Version": "OpenSearch/3.8.0 (opensearch)",
]

private var openSearchFoundationSuccessScenarios: [OpenSearchDatabaseFoundationScenario] {
    [
        .response(
            status: 200,
            headers: openSearchFoundationProductHeaders,
            body: openSearchFoundationRootBody),
        .response(
            status: 200,
            headers: openSearchFoundationProductHeaders,
            body: openSearchFoundationNodesBody),
    ]
}

@Suite(.serialized)
struct OpenSearchDatabaseFoundationTransportTests {
    @Test func connectsWithBoundedAuthenticatedRequests() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure(
            openSearchFoundationSuccessScenarios)
        let plan = try openSearchFoundationPlan()
        let client = try await URLSessionOpenSearchDatabaseClient.connect(
            plan,
            sessionFactory: { openSearchFoundationSession($0) })
        let identity = try await client.discoverIdentity()
        await client.disconnect()

        #expect(identity.product == .openSearch)
        #expect(identity.version?.string == "3.8.0")
        #expect(identity.version?.major == 3)
        #expect(identity.version?.minor == 8)
        #expect(identity.version?.patch == 0)
        #expect(identity.distribution == "OpenSearch")
        #expect(identity.serverIdentifier == "cluster-identifier")
        #expect(identity.topology.kind == .standalone)
        #expect(identity.topology.name == "edith-search")
        #expect(identity.topology.localRole == "cluster-manager-eligible")
        #expect(identity.topology.nodeCount == 1)
        #expect(
            identity.modules
                == [DatabaseExtensionIdentity(name: "lang-painless", version: "3.8.0")])
        #expect(
            identity.plugins
                == [
                    DatabaseExtensionIdentity(
                        name: "opensearch-security",
                        version: "3.8.0.0")
                ])

        let snapshot = OpenSearchDatabaseFoundationURLProtocol.state.snapshot()
        #expect(snapshot.requests.count == 2)
        let expectedAuthorization = OpenSearchDatabaseAuthorization.basic(
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

    @Test func acceptsAuthoritativeRootFieldsWithoutOptionalVersionHeader() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: openSearchFoundationRootBody),
            .response(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: openSearchFoundationNodesBody),
        ])
        let client = try await URLSessionOpenSearchDatabaseClient.connect(
            openSearchFoundationPlan(),
            sessionFactory: { openSearchFoundationSession($0) })
        #expect(try await client.discoverIdentity().product == .openSearch)
        await client.disconnect()
    }

    @Test func rejectsElasticsearchBeforeTopologyDiscovery() async throws {
        let elasticsearchBody = Data(
            """
            {
              "name": "elastic-node",
              "cluster_name": "elastic-cluster",
              "cluster_uuid": "elastic-cluster-id",
              "version": {
                "number": "9.5.2",
                "build_type": "docker",
                "build_hash": "abcdef",
                "build_date": "2026-08-01T00:00:00Z",
                "build_snapshot": false,
                "lucene_version": "10.5.0",
                "minimum_wire_compatibility_version": "8.19.0",
                "minimum_index_compatibility_version": "8.0.0"
              },
              "tagline": "You Know, for Search"
            }
            """.utf8)
        OpenSearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-Elastic-Product": "Elasticsearch",
                ],
                body: elasticsearchBody)
        ])
        let plan = try openSearchFoundationPlan()
        await #expect(throws: OpenSearchDatabaseDriverFailure.unsupportedProduct) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                plan,
                sessionFactory: { openSearchFoundationSession($0) })
        }
        #expect(OpenSearchDatabaseFoundationURLProtocol.state.snapshot().requests.count == 1)
    }

    @Test func rejectsConflictingProductHeaders() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-Elastic-Product": "Elasticsearch",
                    "X-OpenSearch-Version": "OpenSearch/3.8.0 (opensearch)",
                ],
                body: openSearchFoundationRootBody)
        ])
        await #expect(throws: OpenSearchDatabaseDriverFailure.unsupportedProduct) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                openSearchFoundationPlan(),
                sessionFactory: { openSearchFoundationSession($0) })
        }
    }

    @Test func rejectsMismatchedOpenSearchVersionHeaders() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "X-OpenSearch-Version": "OpenSearch/2.19.0 (opensearch)",
                ],
                body: openSearchFoundationRootBody)
        ])
        await #expect(throws: OpenSearchDatabaseDriverFailure.invalidResponse) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                openSearchFoundationPlan(),
                sessionFactory: { openSearchFoundationSession($0) })
        }
    }

    @Test func mapsAuthenticationWithoutRetainingServerDetails() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    """
                    {"error":{"reason":"credential detail must stay private"}}
                    """.utf8))
        ])
        await #expect(throws: OpenSearchDatabaseDriverFailure.authentication) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                openSearchFoundationPlan(),
                sessionFactory: { openSearchFoundationSession($0) })
        }
    }

    @Test func rejectsResponsesAboveTheConfiguredBound() async throws {
        let oversized = Data(repeating: 65, count: 2_048)
        OpenSearchDatabaseFoundationURLProtocol.state.configure([
            .response(
                status: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": String(oversized.count),
                    "X-OpenSearch-Version": "OpenSearch/3.8.0 (opensearch)",
                ],
                body: oversized)
        ])
        let plan = try openSearchFoundationPlan(maximumResponseBytes: 1_024)
        await #expect(throws: OpenSearchDatabaseDriverFailure.responseTooLarge) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                plan,
                sessionFactory: { openSearchFoundationSession($0) })
        }
    }

    @Test func rejectsRedirectsWithoutReplayingCredentials() async throws {
        for target in [
            "https://search.example.test/redirected",
            "https://redirect-target.example.test/capture",
        ] {
            let targetURL = try #require(URL(string: target))
            OpenSearchDatabaseFoundationURLProtocol.state.configure([
                .redirect(status: 307, target: targetURL),
                .response(
                    status: 200,
                    headers: openSearchFoundationProductHeaders,
                    body: openSearchFoundationRootBody),
            ])
            let plan = try openSearchFoundationPlan()
            await #expect(throws: OpenSearchDatabaseDriverFailure.connection) {
                _ = try await URLSessionOpenSearchDatabaseClient.connect(
                    plan,
                    sessionFactory: { openSearchFoundationSession($0) })
            }
            let requests = OpenSearchDatabaseFoundationURLProtocol.state.snapshot().requests
            #expect(requests.count == 1)
            #expect(requests[0].url == "https://search.example.test/base/")
            #expect(requests[0].authorization == plan.authorization.headerValue)
            #expect(requests.allSatisfy { !$0.url.contains("redirect") })
        }
    }

    @Test func cancelsStalledConnectionsAndReconnectsPromptly() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure([.stalled])
        let plan = try openSearchFoundationPlan(
            connectTimeoutMilliseconds: 5_000,
            requestTimeoutMilliseconds: 5_000)
        let startedAt = ContinuousClock.now
        let task = Task {
            try await URLSessionOpenSearchDatabaseClient.connect(
                plan,
                sessionFactory: { openSearchFoundationSession($0) })
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
        try await waitForOpenSearchFoundationStop()

        OpenSearchDatabaseFoundationURLProtocol.state.configure(
            openSearchFoundationSuccessScenarios)
        let recovered = try await URLSessionOpenSearchDatabaseClient.connect(
            plan,
            sessionFactory: { openSearchFoundationSession($0) })
        #expect(try await recovered.discoverIdentity().product == .openSearch)
        await recovered.disconnect()
    }

    @Test func timesOutStalledRequestsAndReconnectsPromptly() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure([.stalled])
        let plan = try openSearchFoundationPlan(
            connectTimeoutMilliseconds: 5_000,
            requestTimeoutMilliseconds: 150)
        let startedAt = ContinuousClock.now
        await #expect(throws: OpenSearchDatabaseDriverFailure.timeout) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                plan,
                sessionFactory: { openSearchFoundationSession($0) })
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
        try await waitForOpenSearchFoundationStop()

        OpenSearchDatabaseFoundationURLProtocol.state.configure(
            openSearchFoundationSuccessScenarios)
        let recovered = try await URLSessionOpenSearchDatabaseClient.connect(
            plan,
            sessionFactory: { openSearchFoundationSession($0) })
        #expect(try await recovered.discoverIdentity().version?.string == "3.8.0")
        await recovered.disconnect()
    }

    @Test func disconnectedClientsCannotReuseIdentity() async throws {
        OpenSearchDatabaseFoundationURLProtocol.state.configure(
            openSearchFoundationSuccessScenarios)
        let client = try await URLSessionOpenSearchDatabaseClient.connect(
            openSearchFoundationPlan(),
            sessionFactory: { openSearchFoundationSession($0) })
        _ = try await client.discoverIdentity()
        await client.disconnect()
        await #expect(throws: OpenSearchDatabaseDriverFailure.connection) {
            _ = try await client.discoverIdentity()
        }
    }
}

private func waitForOpenSearchFoundationStop() async throws {
    for _ in 0..<50 {
        if OpenSearchDatabaseFoundationURLProtocol.state.snapshot().stoppedRequestCount > 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("stalled URL request was not cancelled")
}

@Test func openSearchFoundationAuthorizationValuesAreTypedAndValidated() throws {
    #expect(OpenSearchDatabaseAuthorization.none.headerValue == nil)
    #expect(
        OpenSearchDatabaseAuthorization.bearer(token: "fixture-token").headerValue
            == "Bearer fixture-token")
    #expect(
        OpenSearchDatabaseAuthorization.apiKey(
            identifier: "fixture-id",
            secret: "fixture-secret"
        ).headerValue?.hasPrefix("ApiKey ") == true)
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
        try OpenSearchDatabaseAuthorization.basic(
            username: "invalid:name",
            password: "fixture-password"
        ).validate()
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
        try OpenSearchDatabaseAuthorization.bearer(token: "unsafe\nvalue").validate()
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
        try OpenSearchDatabaseAuthorization.apiKey(
            identifier: "",
            secret: "fixture-secret"
        ).validate()
    }
}

@Test func openSearchFoundationConnectionPlansRejectUnsafeEndpoints() throws {
    let valid = try openSearchFoundationPlan(endpoint: "https://search.example.test:9200/prefix")
    try OpenSearchDatabaseTransport.validate(valid)
    for endpoint in [
        "ftp://search.example.test",
        "https://reader:fixture-password@search.example.test",
        "https://search.example.test?token=unsafe",
        "https://search.example.test#fragment",
        "https://search.example.test/%2E%2E/private",
    ] {
        let plan = try openSearchFoundationPlan(endpoint: endpoint)
        #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
            try OpenSearchDatabaseTransport.validate(plan)
        }
    }
}

@Test func openSearchFoundationRequestsRejectUnboundedOrUnsafeInputs() throws {
    let endpoint = try #require(URL(string: "https://search.example.test"))
    let excessiveItems = (0...64).map {
        URLQueryItem(name: "field-\($0)", value: "value")
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
        _ = try OpenSearchDatabaseTransport.request(
            endpoint: endpoint,
            path: "/_nodes",
            queryItems: excessiveItems,
            authorization: .none)
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
        _ = try OpenSearchDatabaseTransport.request(
            endpoint: endpoint,
            path: "/../private",
            queryItems: [],
            authorization: .none)
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidConfiguration) {
        _ = try OpenSearchDatabaseTransport.request(
            endpoint: endpoint,
            path: "/_nodes",
            queryItems: [URLQueryItem(name: "unsafe\nname", value: "value")],
            authorization: .none)
    }
}

@Test func openSearchFoundationMapsPartialAndMixedTopology() throws {
    let root = openSearchFoundationRoot()
    let nodes = OpenSearchDatabaseNodesResponse(
        summary: OpenSearchDatabaseNodesResponse.Summary(
            total: 3,
            successful: 2,
            failed: 1),
        clusterName: "edith-search",
        nodes: [
            "a": OpenSearchDatabaseNodesResponse.Node(
                name: "node-a",
                version: "3.8.0",
                roles: ["cluster_manager", "data"],
                plugins: [
                    OpenSearchDatabaseNodesResponse.Extension(
                        name: "opensearch-security",
                        version: "3.8.0.0")
                ],
                modules: []),
            "b": OpenSearchDatabaseNodesResponse.Node(
                name: "node-b",
                version: "3.7.0",
                roles: ["data"],
                plugins: [
                    OpenSearchDatabaseNodesResponse.Extension(
                        name: "opensearch-security",
                        version: "3.7.0.0")
                ],
                modules: []),
        ])
    let identity = try OpenSearchDatabaseDriverSupport.identity(
        root: root,
        nodes: nodes)
    #expect(identity.topology.kind == .cluster)
    #expect(identity.topology.nodeCount == 3)
    #expect(identity.topology.localRole == "cluster-manager-eligible")
    #expect(identity.plugins.count == 2)
    #expect(
        identity.compatibilityNotes
            == [
                "Node topology discovery returned partial results.",
                "Cluster nodes report mixed OpenSearch versions.",
            ])
}

@Test func openSearchFoundationRejectsInvalidOrUnboundedIdentity() throws {
    let root = openSearchFoundationRoot()
    let mismatched = OpenSearchDatabaseNodesResponse(
        summary: OpenSearchDatabaseNodesResponse.Summary(
            total: 1,
            successful: 1,
            failed: 0),
        clusterName: "another-cluster",
        nodes: [
            "a": OpenSearchDatabaseNodesResponse.Node(
                name: "node-a",
                version: "3.8.0",
                roles: [],
                plugins: [],
                modules: [])
        ])
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidResponse) {
        _ = try OpenSearchDatabaseDriverSupport.identity(root: root, nodes: mismatched)
    }

    let extensions = (0...128).map {
        OpenSearchDatabaseNodesResponse.Extension(
            name: "plugin-\($0)",
            version: "3.8.0")
    }
    let excessive = OpenSearchDatabaseNodesResponse(
        summary: OpenSearchDatabaseNodesResponse.Summary(
            total: 1,
            successful: 1,
            failed: 0),
        clusterName: "edith-search",
        nodes: [
            "a": OpenSearchDatabaseNodesResponse.Node(
                name: "node-a",
                version: "3.8.0",
                roles: [],
                plugins: extensions,
                modules: [])
        ])
    #expect(throws: OpenSearchDatabaseDriverFailure.responseTooLarge) {
        _ = try OpenSearchDatabaseDriverSupport.identity(root: root, nodes: excessive)
    }
}

private func openSearchFoundationRoot() -> OpenSearchDatabaseRootResponse {
    OpenSearchDatabaseRootResponse(
        name: "node-a",
        clusterName: "edith-search",
        clusterUUID: "cluster-id",
        version: OpenSearchDatabaseRootResponse.Version(
            distribution: "opensearch",
            number: "3.8.0",
            buildType: "tar",
            buildHash: "abcdef",
            buildDate: "2026-08-01T18:48:00Z",
            buildSnapshot: false,
            luceneVersion: "10.5.0",
            minimumWireCompatibilityVersion: "2.19.0",
            minimumIndexCompatibilityVersion: "2.0.0"),
        tagline: "The OpenSearch Project: https://opensearch.org/")
}

@Test func openSearchFoundationDriverErrorsRemainTypedAndRedacted() throws {
    #expect(
        try OpenSearchDatabaseDriverErrorClassifier.classify(
            URLError(.timedOut)) == .timeout)
    #expect(
        try OpenSearchDatabaseDriverErrorClassifier.classify(
            URLError(.serverCertificateUntrusted)) == .tls)
    #expect(
        try OpenSearchDatabaseDriverErrorClassifier.classify(
            OpenSearchDatabaseFoundationUnknownFailure()) == .connection)
    #expect(throws: CancellationError.self) {
        _ = try OpenSearchDatabaseDriverErrorClassifier.classify(CancellationError())
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.permission(403)) {
        try OpenSearchDatabaseDriverErrorClassifier.validate(
            OpenSearchDatabaseHTTPResponse(
                statusCode: 403,
                openSearchVersionHeader: nil,
                elasticProductHeader: nil,
                body: Data()))
    }
    #expect(throws: OpenSearchDatabaseDriverFailure.server(500)) {
        try OpenSearchDatabaseDriverErrorClassifier.validate(
            OpenSearchDatabaseHTTPResponse(
                statusCode: 999,
                openSearchVersionHeader: nil,
                elasticProductHeader: nil,
                body: Data()))
    }
}

private enum OpenSearchDatabaseLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_OPENSEARCH_URL",
        "EDITH_DATABASE_OPENSEARCH_USERNAME",
        "EDITH_DATABASE_OPENSEARCH_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }

    static func plan(
        passwordSuffix: String = "",
        maximumResponseBytes: Int = 2_097_152
    ) throws -> OpenSearchDatabaseConnectionPlan {
        let endpoint = try #require(values["EDITH_DATABASE_OPENSEARCH_URL"])
        let username = try #require(values["EDITH_DATABASE_OPENSEARCH_USERNAME"])
        let password = try #require(values["EDITH_DATABASE_OPENSEARCH_PASSWORD"])
        return try openSearchFoundationPlan(
            endpoint: endpoint,
            authorization: .basic(
                username: username,
                password: password + passwordSuffix),
            connectTimeoutMilliseconds: 5_000,
            requestTimeoutMilliseconds: 5_000,
            maximumResponseBytes: maximumResponseBytes)
    }
}

private final class OpenSearchDatabaseLiveURLSessionDelegate: NSObject, URLSessionDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        task.cancel()
        completionHandler(nil)
    }
}

private func openSearchDatabaseLiveSession(
    _ plan: OpenSearchDatabaseConnectionPlan
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest =
        TimeInterval(plan.connectTimeoutMilliseconds) / 1_000
    configuration.timeoutIntervalForResource =
        TimeInterval(plan.requestTimeoutMilliseconds) / 1_000
    configuration.waitsForConnectivity = false
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    return URLSession(
        configuration: configuration,
        delegate: OpenSearchDatabaseLiveURLSessionDelegate(),
        delegateQueue: nil)
}

@Suite(.serialized)
struct OpenSearchDatabaseFoundationLiveTests {
    @Test(.enabled(if: OpenSearchDatabaseLiveEnvironment.isEnabled))
    func authenticatedIdentity() async throws {
        let client = try await URLSessionOpenSearchDatabaseClient.connect(
            OpenSearchDatabaseLiveEnvironment.plan(),
            sessionFactory: { openSearchDatabaseLiveSession($0) })
        let identity: DatabaseProductIdentity
        do {
            identity = try await client.discoverIdentity()
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
        #expect(identity.product == .openSearch)
        #expect(identity.version?.string == "3.8.0")
        #expect(identity.distribution == "OpenSearch")
        #expect(identity.topology.kind == .standalone)
        #expect(identity.topology.nodeCount == 1)
        #expect(identity.plugins.contains { $0.name == "opensearch-security" })
        let version = identity.version?.string ?? "unknown"
        let nodeCount = identity.topology.nodeCount ?? 0
        print("opensearch live verified version=\(version) nodes=\(nodeCount)")
    }

    @Test(.enabled(if: OpenSearchDatabaseLiveEnvironment.isEnabled))
    func rejectsInvalidAuthentication() async throws {
        await #expect(throws: OpenSearchDatabaseDriverFailure.authentication) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                OpenSearchDatabaseLiveEnvironment.plan(passwordSuffix: "-invalid"),
                sessionFactory: { openSearchDatabaseLiveSession($0) })
        }
    }

    @Test(.enabled(if: OpenSearchDatabaseLiveEnvironment.isEnabled))
    func repeatedConnectionLifecycle() async throws {
        let plan = try OpenSearchDatabaseLiveEnvironment.plan()
        for _ in 0..<4 {
            let client = try await URLSessionOpenSearchDatabaseClient.connect(
                plan,
                sessionFactory: { openSearchDatabaseLiveSession($0) })
            _ = try await client.discoverIdentity()
            await client.disconnect()
            await #expect(throws: OpenSearchDatabaseDriverFailure.connection) {
                _ = try await client.discoverIdentity()
            }
        }
    }

    @Test(.enabled(if: OpenSearchDatabaseLiveEnvironment.isEnabled))
    func cancelledConnectionLeavesAReusableEndpoint() async throws {
        let plan = try OpenSearchDatabaseLiveEnvironment.plan()
        let startedAt = ContinuousClock.now
        let task = Task {
            try await URLSessionOpenSearchDatabaseClient.connect(
                plan,
                sessionFactory: { openSearchDatabaseLiveSession($0) })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))

        let recovered = try await URLSessionOpenSearchDatabaseClient.connect(
            plan,
            sessionFactory: { openSearchDatabaseLiveSession($0) })
        #expect(try await recovered.discoverIdentity().product == .openSearch)
        await recovered.disconnect()
    }

    @Test(.enabled(if: OpenSearchDatabaseLiveEnvironment.isEnabled))
    func rejectsLiveTopologyAboveTheConfiguredResponseBound() async throws {
        await #expect(throws: OpenSearchDatabaseDriverFailure.responseTooLarge) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                OpenSearchDatabaseLiveEnvironment.plan(maximumResponseBytes: 1_024),
                sessionFactory: { openSearchDatabaseLiveSession($0) })
        }
    }

    @Test(.enabled(if: OpenSearchDatabaseLiveEnvironment.isEnabled))
    func productionSessionRejectsTheDemoCertificate() async throws {
        await #expect(throws: OpenSearchDatabaseDriverFailure.tls) {
            _ = try await URLSessionOpenSearchDatabaseClient.connect(
                OpenSearchDatabaseLiveEnvironment.plan())
        }
    }
}
