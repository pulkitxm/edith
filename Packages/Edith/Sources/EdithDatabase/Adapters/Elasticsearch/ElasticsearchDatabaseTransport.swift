import Foundation

struct ElasticsearchDatabaseHTTPResponse: Sendable {
    let statusCode: Int
    let productHeader: String?
    let body: Data
}

enum ElasticsearchDatabaseTransport {
    static let minimumResponseBytes = 1_024
    static let maximumResponseBytes = 16_777_216

    static func makeSession(
        _ plan: ElasticsearchDatabaseConnectionPlan
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        let connectionTimeout = TimeInterval(plan.connectTimeoutMilliseconds) / 1_000
        let requestTimeout = TimeInterval(plan.requestTimeoutMilliseconds) / 1_000
        configuration.timeoutIntervalForRequest = connectionTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    static func validate(
        _ plan: ElasticsearchDatabaseConnectionPlan
    ) throws(ElasticsearchDatabaseDriverFailure) {
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
        authorization: ElasticsearchDatabaseAuthorization
    ) throws(ElasticsearchDatabaseDriverFailure) -> URLRequest {
        guard path.hasPrefix("/"),
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
        guard let url = components.url else {
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
    ) async throws -> ElasticsearchDatabaseHTTPResponse {
        do {
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw ElasticsearchDatabaseDriverFailure.invalidResponse
                }
                if response.expectedContentLength > Int64(maximumResponseBytes) {
                    throw ElasticsearchDatabaseDriverFailure.responseTooLarge
                }
                var body = Data()
                if response.expectedContentLength > 0 {
                    body.reserveCapacity(
                        min(Int(response.expectedContentLength), maximumResponseBytes))
                }
                var iterator = bytes.makeAsyncIterator()
                while let byte = try await iterator.next() {
                    if body.count == maximumResponseBytes {
                        throw ElasticsearchDatabaseDriverFailure.responseTooLarge
                    }
                    body.append(byte)
                    if body.count.isMultiple(of: 4_096) {
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                return ElasticsearchDatabaseHTTPResponse(
                    statusCode: response.statusCode,
                    productHeader: response.value(
                        forHTTPHeaderField: "X-Elastic-Product"),
                    body: body)
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch let failure as ElasticsearchDatabaseDriverFailure {
            if failure == .responseTooLarge {
                session.invalidateAndCancel()
            }
            throw failure
        }
    }
}

enum ElasticsearchDatabaseDeadline {
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
                throw ElasticsearchDatabaseDriverFailure.timeout
            }
            defer { group.cancelAll() }
            guard let output = try await group.next() else {
                throw ElasticsearchDatabaseDriverFailure.connection
            }
            return output
        }
    }
}
