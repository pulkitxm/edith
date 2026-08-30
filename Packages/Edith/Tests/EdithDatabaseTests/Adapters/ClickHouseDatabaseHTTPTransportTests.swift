import Foundation
import Testing

@testable import EdithDatabase

enum ClickHouseDatabaseHTTPStubAction: @unchecked Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data)
    case failure(URLError)
    case stall
}

func clickHouseDatabaseRequestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

final class ClickHouseDatabaseHTTPStub: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> ClickHouseDatabaseHTTPStubAction

    private let lock = NSLock()
    private let handler: Handler
    private var recordedRequests: [URLRequest] = []
    private var recordedStops = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func action(for request: URLRequest) -> ClickHouseDatabaseHTTPStubAction {
        lock.withLock {
            recordedRequests.append(request)
        }
        return handler(request)
    }

    func stopped() {
        lock.withLock {
            recordedStops += 1
        }
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    var stopCount: Int {
        lock.withLock { recordedStops }
    }
}

final class ClickHouseDatabaseHTTPStubRegistry: @unchecked Sendable {
    static let shared = ClickHouseDatabaseHTTPStubRegistry()

    private let lock = NSLock()
    private var stubs: [String: ClickHouseDatabaseHTTPStub] = [:]

    func register(_ stub: ClickHouseDatabaseHTTPStub, host: String) {
        lock.withLock {
            stubs[host] = stub
        }
    }

    func remove(host: String) {
        _ = lock.withLock {
            stubs.removeValue(forKey: host)
        }
    }

    func stub(host: String?) -> ClickHouseDatabaseHTTPStub? {
        guard let host else { return nil }
        return lock.withLock { stubs[host] }
    }
}

final class ClickHouseDatabaseTestURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var stub: ClickHouseDatabaseHTTPStub?

    override class func canInit(with request: URLRequest) -> Bool {
        ClickHouseDatabaseHTTPStubRegistry.shared.stub(host: request.url?.host()) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let stub = ClickHouseDatabaseHTTPStubRegistry.shared.stub(
                host: request.url?.host())
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        self.stub = stub
        switch stub.action(for: request) {
        case let .response(statusCode, headers, body):
            guard
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "http://invalid.invalid/")!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < body.count, !isStopped {
                let length = min(257, body.count - offset)
                client?.urlProtocol(
                    self,
                    didLoad: body.subdata(in: offset..<(offset + length)))
                offset += length
            }
            if !isStopped {
                client?.urlProtocolDidFinishLoading(self)
            }
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case .stall:
            break
        }
    }

    override func stopLoading() {
        lock.withLock {
            stopped = true
        }
        stub?.stopped()
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }
}

struct ClickHouseDatabaseHTTPTestHarness {
    let host: String
    let stub: ClickHouseDatabaseHTTPStub
    let configuration: URLSessionConfiguration
    let plan: ClickHouseDatabaseConnectionPlan

    init(
        readOnly: Bool = true,
        timeoutMilliseconds: UInt64 = 2_000,
        handler: @escaping ClickHouseDatabaseHTTPStub.Handler
    ) {
        host = "\(UUID().uuidString.lowercased()).example.test"
        stub = ClickHouseDatabaseHTTPStub(handler: handler)
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClickHouseDatabaseTestURLProtocol.self]
        plan = ClickHouseDatabaseConnectionPlan(
            host: host,
            port: 8_123,
            username: "reader",
            password: "fixture-password",
            database: "edith_lab",
            tls: .disabled,
            requestTimeoutMilliseconds: timeoutMilliseconds,
            readOnly: readOnly)
        ClickHouseDatabaseHTTPStubRegistry.shared.register(stub, host: host)
    }

    func remove() {
        ClickHouseDatabaseHTTPStubRegistry.shared.remove(host: host)
    }
}

@Test func clickHouseHTTPTransportUsesHeadersAndBoundedSettings() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"value\":1}\n".utf8))
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let response = try await transport.execute(
        query: "SELECT 1 FORMAT JSONEachRow",
        maximumResponseBytes: 4_096)
    await transport.close()
    #expect(response.statusCode == 200)
    #expect(response.body == Data("{\"value\":1}\n".utf8))
    let request = try #require(harness.stub.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(
        clickHouseDatabaseRequestBody(request)
            == Data("SELECT 1 FORMAT JSONEachRow".utf8))
    #expect(request.value(forHTTPHeaderField: "X-ClickHouse-User") == "reader")
    #expect(request.value(forHTTPHeaderField: "X-ClickHouse-Key") == "fixture-password")
    #expect(request.value(forHTTPHeaderField: "X-ClickHouse-Database") == "edith_lab")
    #expect(request.url?.absoluteString.contains("fixture-password") == false)
    let requestURL = try #require(request.url)
    let components = try #require(
        URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
    let settings = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    #expect(settings["readonly"] == "1")
    #expect(settings["wait_end_of_query"] == "1")
    #expect(settings["max_result_bytes"] == "4096")
    #expect(settings["max_execution_time"] == "2")
    #expect(UUID(uuidString: settings["query_id"] ?? "") != nil)
}

@Test func clickHouseHTTPTransportBindsValidatedQueryParameters() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(statusCode: 200, headers: [:], body: Data())
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    _ = try await transport.execute(
        query: "SELECT {minimum:UInt64}",
        maximumResponseBytes: 4_096,
        parameters: [
            ClickHouseDatabaseHTTPParameter(name: "minimum", value: "42")
        ])
    await transport.close()
    let request = try #require(harness.stub.requests.first)
    let requestURL = try #require(request.url)
    let components = try #require(
        URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
    let items = components.queryItems ?? []
    #expect(items.filter { $0.name == "param_minimum" }.map(\.value) == ["42"])
    #expect(items.filter { $0.name == "result_overflow_mode" }.count == 1)
    #expect(items.filter { $0.name == "output_format_json_quote_decimals" }.map(\.value) == ["1"])
}

@Test func clickHouseHTTPTransportRejectsInvalidQueryParametersBeforeNetworkUse() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(statusCode: 200, headers: [:], body: Data())
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    await #expect(throws: ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration) {
        _ = try await transport.execute(
            query: "SELECT {value:String}",
            maximumResponseBytes: 4_096,
            parameters: [
                ClickHouseDatabaseHTTPParameter(name: "bad-name", value: "secret"),
                ClickHouseDatabaseHTTPParameter(name: "bad-name", value: "duplicate"),
            ])
    }
    #expect(harness.stub.requests.isEmpty)
    await transport.close()
}

@Test func clickHouseHTTPTransportRejectsDeclaredOversizedResponses() async throws {
    let body = Data(repeating: 65, count: 4_097)
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(
            statusCode: 200,
            headers: ["Content-Length": String(body.count)],
            body: body)
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    await #expect(throws: ClickHouseDatabaseHTTPTransportFailure.responseTooLarge) {
        _ = try await transport.execute(
            query: "SELECT 1",
            maximumResponseBytes: 4_096)
    }
    await transport.close()
}

@Test func clickHouseHTTPTransportRejectsUnboundedResponseLimits() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(statusCode: 200, headers: [:], body: Data())
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    await #expect(throws: ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration) {
        _ = try await transport.execute(
            query: "SELECT 1",
            maximumResponseBytes: ClickHouseDatabaseHTTPTransport.maximumBufferedResponseBytes
                + 1)
    }
    #expect(harness.stub.requests.isEmpty)
    await transport.close()
}

@Test func clickHouseHTTPTransportRejectsMalformedCredentialsDuringConstruction() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ClickHouseDatabaseTestURLProtocol.self]
    let plan = ClickHouseDatabaseConnectionPlan(
        host: "127.0.0.1",
        port: 8_123,
        username: "reader",
        password: "secret\nX-Injected: value",
        database: "edith_lab",
        tls: .disabled,
        requestTimeoutMilliseconds: 2_000,
        readOnly: true)
    #expect(throws: ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration) {
        _ = try ClickHouseDatabaseHTTPTransport(
            plan: plan,
            configuration: configuration)
    }
}

@Test func clickHouseHTTPTransportRejectsStreamedOversizedResponses() async throws {
    let body = Data(repeating: 65, count: 4_097)
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(statusCode: 200, headers: [:], body: body)
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    await #expect(throws: ClickHouseDatabaseHTTPTransportFailure.responseTooLarge) {
        _ = try await transport.execute(
            query: "SELECT 1",
            maximumResponseBytes: 4_096)
    }
    await transport.close()
}

@Test func clickHouseHTTPTransportKeepsOnlySafeExceptionCodes() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { _ in
        .response(
            statusCode: 403,
            headers: ["X-ClickHouse-Exception-Code": "497"],
            body: Data("sensitive server detail".utf8))
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    await #expect(
        throws: ClickHouseDatabaseHTTPTransportFailure.http(
            statusCode: 403,
            exceptionCode: "497")
    ) {
        _ = try await transport.execute(
            query: "SELECT 1",
            maximumResponseBytes: 4_096)
    }
    await transport.close()
}

@Test func clickHouseHTTPTransportCancelsAndKillsActiveQueries() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { request in
        if String(data: clickHouseDatabaseRequestBody(request), encoding: .utf8)?.hasPrefix(
            "KILL QUERY")
            == true
        {
            return .response(statusCode: 200, headers: [:], body: Data())
        }
        return .stall
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let query = Task {
        try await transport.execute(
            query: "SELECT sleep(10)",
            maximumResponseBytes: 4_096)
    }
    for _ in 0..<100 where harness.stub.requests.isEmpty {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let startedAt = ContinuousClock.now
    query.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await query.value
    }
    #expect(ContinuousClock.now - startedAt < .seconds(1))
    #expect(
        harness.stub.requests.contains { request in
            String(data: clickHouseDatabaseRequestBody(request), encoding: .utf8)?.hasPrefix(
                "KILL QUERY")
                == true
        })
    await transport.close()
}

@Test func clickHouseHTTPTransportCloseInterruptsInFlightRequests() async throws {
    let harness = ClickHouseDatabaseHTTPTestHarness { request in
        if String(data: clickHouseDatabaseRequestBody(request), encoding: .utf8)?.hasPrefix(
            "KILL QUERY")
            == true
        {
            return .response(statusCode: 200, headers: [:], body: Data())
        }
        return .stall
    }
    defer { harness.remove() }
    let transport = try ClickHouseDatabaseHTTPTransport(
        plan: harness.plan,
        configuration: harness.configuration)
    let query = Task {
        try await transport.execute(
            query: "SELECT sleep(10)",
            maximumResponseBytes: 4_096)
    }
    for _ in 0..<100 where harness.stub.requests.isEmpty {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let startedAt = ContinuousClock.now
    await transport.close()
    await #expect(throws: CancellationError.self) {
        _ = try await query.value
    }
    #expect(ContinuousClock.now - startedAt < .seconds(1))
    #expect(harness.stub.stopCount > 0)
}
