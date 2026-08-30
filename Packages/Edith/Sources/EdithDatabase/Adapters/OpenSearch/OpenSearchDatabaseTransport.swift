import Foundation

struct OpenSearchDatabaseHTTPResponse: Sendable {
    let statusCode: Int
    let openSearchVersionHeader: String?
    let elasticProductHeader: String?
    let body: Data
}

final class OpenSearchDatabaseURLSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
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

enum OpenSearchDatabaseTransport {
    static let minimumResponseBytes = 1_024
    static let maximumResponseBytes = 16_777_216
    private static let maximumPathBytes = 4_096
    private static let maximumQueryItems = 64
    private static let maximumQueryComponentBytes = 4_096

    static func makeSession(
        _ plan: OpenSearchDatabaseConnectionPlan
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        let connectionTimeout = TimeInterval(plan.connectTimeoutMilliseconds) / 1_000
        let requestTimeout = TimeInterval(plan.requestTimeoutMilliseconds) / 1_000
        configuration.timeoutIntervalForRequest = connectionTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: OpenSearchDatabaseURLSessionDelegate(),
            delegateQueue: nil)
    }

    static func validate(
        _ plan: OpenSearchDatabaseConnectionPlan
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard
            let components = URLComponents(
                url: plan.endpoint,
                resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.percentEncodedPath.utf8.count <= maximumPathBytes,
            safePath(components.path),
            plan.connectTimeoutMilliseconds >= 100,
            plan.requestTimeoutMilliseconds >= 100,
            plan.connectTimeoutMilliseconds <= 86_400_000,
            plan.requestTimeoutMilliseconds <= 86_400_000,
            (minimumResponseBytes...maximumResponseBytes).contains(plan.maximumResponseBytes)
        else {
            throw .invalidConfiguration
        }
        try plan.authorization.validate()
    }

    static func request(
        endpoint: URL,
        path: String,
        queryItems: [URLQueryItem],
        authorization: OpenSearchDatabaseAuthorization
    ) throws(OpenSearchDatabaseDriverFailure) -> URLRequest {
        guard path.hasPrefix("/"),
            path.utf8.count <= maximumPathBytes,
            safePath(path),
            queryItems.count <= maximumQueryItems,
            queryItems.allSatisfy({ safeQueryComponent($0.name) }),
            queryItems.allSatisfy({ $0.value.map(safeQueryComponent) ?? true }),
            var components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false)
        else {
            throw .invalidConfiguration
        }
        let prefix =
            components.percentEncodedPath == "/"
            ? ""
            : components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = prefix.isEmpty ? path : "/\(prefix)\(path)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url,
            url.absoluteString.utf8.count <= 16_384
        else {
            throw .invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("edith-database", forHTTPHeaderField: "X-Opaque-Id")
        if let value = authorization.headerValue {
            request.setValue(value, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func execute(
        session: URLSession,
        request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> OpenSearchDatabaseHTTPResponse {
        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw OpenSearchDatabaseDriverFailure.invalidResponse
                }
                if response.expectedContentLength > Int64(maximumResponseBytes) {
                    throw OpenSearchDatabaseDriverFailure.responseTooLarge
                }
                var body = Data()
                if response.expectedContentLength > 0 {
                    body.reserveCapacity(
                        min(Int(response.expectedContentLength), maximumResponseBytes))
                }
                var iterator = bytes.makeAsyncIterator()
                while let byte = try await iterator.next() {
                    if body.count == maximumResponseBytes {
                        throw OpenSearchDatabaseDriverFailure.responseTooLarge
                    }
                    body.append(byte)
                    if body.count.isMultiple(of: 4_096) {
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                return OpenSearchDatabaseHTTPResponse(
                    statusCode: response.statusCode,
                    openSearchVersionHeader: response.value(
                        forHTTPHeaderField: "X-OpenSearch-Version"),
                    elasticProductHeader: response.value(
                        forHTTPHeaderField: "X-Elastic-Product"),
                    body: body)
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch let failure as OpenSearchDatabaseDriverFailure {
            if failure == .responseTooLarge {
                session.invalidateAndCancel()
            }
            throw failure
        }
    }

    private static func safePath(_ value: String) -> Bool {
        !value.contains("\0") && !value.contains("\r") && !value.contains("\n")
            && !value.split(separator: "/", omittingEmptySubsequences: true)
                .contains(where: { $0 == "." || $0 == ".." })
    }

    private static func safeQueryComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumQueryComponentBytes
            && !value.contains("\0") && !value.contains("\r") && !value.contains("\n")
    }
}

enum OpenSearchDatabaseDeadline {
    static func run<Output: Sendable>(
        milliseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(
                    for: .milliseconds(Int64(clamping: milliseconds)))
                throw OpenSearchDatabaseDriverFailure.timeout
            }
            defer { group.cancelAll() }
            guard let output = try await group.next() else {
                throw OpenSearchDatabaseDriverFailure.connection
            }
            return output
        }
    }
}
