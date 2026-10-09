import Foundation
import Testing

@testable import UsageExtension

private final class UsageResponseFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var body = Data()
    private static var headers: [String: String] = [:]
    private static var started = 0

    static func configure(body: Data, declaredLength: Int?) {
        lock.withLock {
            self.body = body
            headers = declaredLength.map { ["Content-Length": String($0)] } ?? [:]
            started = 0
        }
    }

    static var requestCount: Int { lock.withLock { started } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let fixture = Self.lock.withLock { () -> (Data, [String: String]) in
            Self.started += 1
            return (Self.body, Self.headers)
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fixture.1)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.0)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct UsageHTTPResponseTests {
    @Test func completeResponsePreservesItsBytesAndStatus() async throws {
        let input = Data(#"{"limit":25}"#.utf8)
        UsageResponseFixture.configure(body: input, declaredLength: input.count)
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await UsageHTTPResponse.read(request(), session: session)
        #expect(data == input)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(UsageResponseFixture.requestCount == 1)
    }

    @Test(arguments: [true, false]) func oversizedResponseIsRejected(declared: Bool) async throws {
        UsageResponseFixture.configure(
            body: Data(repeating: 120, count: 1_025), declaredLength: declared ? 1_025 : nil)
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: UsageHTTPResponse.Failure.self) {
            _ = try await UsageHTTPResponse.read(request(), session: session, maximumBytes: 1_024)
        }
    }

    @Test func preCancelledRequestStartsNoNetworkWork() async throws {
        UsageResponseFixture.configure(body: Data("unused".utf8), declaredLength: nil)
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await UsageHTTPResponse.read(request(), session: session)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(UsageResponseFixture.requestCount == 0)
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageResponseFixture.self]
        return URLSession(configuration: configuration)
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://usage-fixture.invalid/limits")!)
    }
}
