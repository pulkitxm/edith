import Foundation

final class UsageNativeNetwork: @unchecked Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport?
    private let started = ContinuousClock.now
    private let maximumBytes: Int

    init(maximumBytes: Int = 33_554_432, transport: Transport? = nil) {
        self.maximumBytes = maximumBytes
        self.transport = transport
    }

    func object(_ request: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now).components
        let remaining = 90 - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
        guard remaining > 0 else { throw URLError(.timedOut) }
        var request = request
        request.timeoutInterval = min(20, remaining)
        let data: Data
        let status: Int
        if let transport {
            (data, status) = try await transport(request)
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForResource = remaining
            let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            (data, status) = try await withTaskCancellationHandler {
                let (stream, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw UsageNativeFailure.invalidInput("HTTP response")
                }
                guard response.expectedContentLength <= maximumBytes else {
                    throw UsageNativeFailure.capacity
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw UsageNativeFailure.network(response.statusCode)
                }
                var received = Data()
                for try await byte in stream {
                    try Task.checkCancellation()
                    guard received.count < maximumBytes else { throw UsageNativeFailure.capacity }
                    received.append(byte)
                }
                return (received, response.statusCode)
            } onCancel: {
                session.invalidateAndCancel()
            }
        }
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw UsageNativeFailure.capacity }
        guard (200..<300).contains(status) else { throw UsageNativeFailure.network(status) }
        return try UsageNativeJSON.object(data)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
