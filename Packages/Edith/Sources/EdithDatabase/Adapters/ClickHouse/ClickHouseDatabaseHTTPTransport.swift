import Foundation

enum ClickHouseDatabaseHTTPTransportFailure: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidResponse
    case responseTooLarge
    case http(statusCode: Int, exceptionCode: String?)
}

struct ClickHouseDatabaseHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let exceptionCode: String?
    let body: Data
}

final class ClickHouseDatabaseHTTPTransport: @unchecked Sendable {
    static let maximumQueryBytes = 1_048_576
    static let maximumCredentialBytes = 16_384
    static let maximumBufferedResponseBytes = 16_777_216

    private let plan: ClickHouseDatabaseConnectionPlan
    private let baseURL: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var activeQueryIDs = Set<UUID>()

    init(
        plan: ClickHouseDatabaseConnectionPlan,
        configuration suppliedConfiguration: URLSessionConfiguration? = nil
    ) throws {
        self.plan = plan
        baseURL = try plan.baseURL()
        guard Self.validHeader(plan.username, maximumBytes: 1_024),
            plan.password.map({ Self.validHeader($0, maximumBytes: Self.maximumCredentialBytes) })
                ?? true,
            plan.database.map({ Self.validHeader($0, maximumBytes: 1_024) }) ?? true
        else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.waitsForConnectivity = false
        let timeout = Self.timeInterval(milliseconds: plan.requestTimeoutMilliseconds)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(
            configuration: configuration,
            delegate: ClickHouseDatabaseURLSessionDelegate(),
            delegateQueue: nil)
    }

    deinit {
        session?.invalidateAndCancel()
    }

    func execute(
        query: String,
        maximumResponseBytes: Int
    ) async throws -> ClickHouseDatabaseHTTPResponse {
        guard !query.isEmpty,
            query.utf8.count <= Self.maximumQueryBytes,
            maximumResponseBytes > 0,
            maximumResponseBytes <= Self.maximumBufferedResponseBytes
        else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        let queryID = UUID()
        let session = try beginQuery(queryID)
        defer {
            finishQuery(queryID)
        }
        let request = try request(
            query: query,
            queryID: queryID,
            maximumResponseBytes: maximumResponseBytes)
        do {
            return try await response(
                session: session,
                request: request,
                maximumResponseBytes: maximumResponseBytes)
        } catch {
            let cancellation = Task {
                await cancel(queryID)
            }
            _ = await cancellation.value
            if error is CancellationError || Task.isCancelled
                || (error as? URLError)?.code == .cancelled
            {
                throw CancellationError()
            }
            throw error
        }
    }

    func cancelActiveQueries() async {
        let queryIDs = lock.withLock { Array(activeQueryIDs) }
        for queryID in queryIDs {
            await cancel(queryID)
        }
    }

    func close() async {
        let state = lock.withLock { () -> (URLSession?, [UUID]) in
            let session = self.session
            self.session = nil
            let queryIDs = Array(activeQueryIDs)
            activeQueryIDs.removeAll(keepingCapacity: false)
            return (session, queryIDs)
        }
        guard let session = state.0 else { return }
        for queryID in state.1 {
            await cancel(queryID, using: session)
        }
        session.invalidateAndCancel()
    }

    private func beginQuery(_ queryID: UUID) throws -> URLSession {
        try lock.withLock {
            guard let session else {
                throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
            }
            activeQueryIDs.insert(queryID)
            return session
        }
    }

    private func finishQuery(_ queryID: UUID) {
        _ = lock.withLock {
            activeQueryIDs.remove(queryID)
        }
    }

    private func request(
        query: String,
        queryID: UUID,
        maximumResponseBytes: Int
    ) throws -> URLRequest {
        let executionSeconds = max(
            1,
            Int(ceil(Double(plan.requestTimeoutMilliseconds) / 1_000)))
        var components = try components(queryItems: [
            URLQueryItem(name: "query_id", value: queryID.uuidString.lowercased()),
            URLQueryItem(name: "wait_end_of_query", value: "1"),
            URLQueryItem(name: "max_execution_time", value: String(executionSeconds)),
            URLQueryItem(name: "max_result_bytes", value: String(maximumResponseBytes)),
            URLQueryItem(name: "result_overflow_mode", value: "throw"),
            URLQueryItem(name: "output_format_json_quote_64bit_integers", value: "0"),
        ])
        if plan.readOnly {
            components.queryItems?.append(URLQueryItem(name: "readonly", value: "1"))
        }
        guard let url = components.url else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(query.utf8)
        request.timeoutInterval = Self.timeInterval(
            milliseconds: plan.requestTimeoutMilliseconds)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Edith", forHTTPHeaderField: "User-Agent")
        try applyAuthentication(to: &request)
        return request
    }

    private func cancellationRequest(
        targetQueryID: UUID
    ) throws -> URLRequest {
        let cancellationID = UUID()
        let components = try components(queryItems: [
            URLQueryItem(name: "query_id", value: cancellationID.uuidString.lowercased()),
            URLQueryItem(name: "param_target", value: targetQueryID.uuidString.lowercased()),
            URLQueryItem(name: "wait_end_of_query", value: "1"),
            URLQueryItem(name: "max_execution_time", value: "1"),
            URLQueryItem(name: "max_result_bytes", value: "16384"),
            URLQueryItem(name: "result_overflow_mode", value: "throw"),
        ])
        guard let url = components.url else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(
            "KILL QUERY WHERE query_id = {target:String} SYNC".utf8)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Edith", forHTTPHeaderField: "User-Agent")
        try applyAuthentication(to: &request)
        return request
    }

    private func components(
        queryItems: [URLQueryItem]
    ) throws -> URLComponents {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        components.queryItems = queryItems
        return components
    }

    private func applyAuthentication(
        to request: inout URLRequest
    ) throws {
        guard Self.validHeader(plan.username, maximumBytes: 1_024),
            plan.password.map({ Self.validHeader($0, maximumBytes: Self.maximumCredentialBytes) })
                ?? true,
            plan.database.map({ Self.validHeader($0, maximumBytes: 1_024) }) ?? true
        else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        request.setValue(plan.username, forHTTPHeaderField: "X-ClickHouse-User")
        if let password = plan.password {
            request.setValue(password, forHTTPHeaderField: "X-ClickHouse-Key")
        }
        if let database = plan.database {
            request.setValue(database, forHTTPHeaderField: "X-ClickHouse-Database")
        }
    }

    private func response(
        session: URLSession,
        request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> ClickHouseDatabaseHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidResponse
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            throw ClickHouseDatabaseHTTPTransportFailure.responseTooLarge
        }
        var body = Data()
        body.reserveCapacity(
            min(maximumResponseBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if Task.isCancelled {
                throw CancellationError()
            }
            guard body.count < maximumResponseBytes else {
                throw ClickHouseDatabaseHTTPTransportFailure.responseTooLarge
            }
            body.append(byte)
        }
        let exceptionCode = Self.safeExceptionCode(
            response.value(forHTTPHeaderField: "X-ClickHouse-Exception-Code"))
        guard (200..<300).contains(response.statusCode) else {
            throw ClickHouseDatabaseHTTPTransportFailure.http(
                statusCode: response.statusCode,
                exceptionCode: exceptionCode)
        }
        return ClickHouseDatabaseHTTPResponse(
            statusCode: response.statusCode,
            exceptionCode: exceptionCode,
            body: body)
    }

    private func cancel(_ queryID: UUID) async {
        guard let session = lock.withLock({ session }) else { return }
        await cancel(queryID, using: session)
    }

    private func cancel(
        _ queryID: UUID,
        using session: URLSession
    ) async {
        do {
            let request = try cancellationRequest(targetQueryID: queryID)
            _ = try await response(
                session: session,
                request: request,
                maximumResponseBytes: 16_384)
        } catch {
        }
    }

    private static func timeInterval(milliseconds: UInt64) -> TimeInterval {
        max(0.001, min(Double(milliseconds) / 1_000, Double(Int32.max)))
    }

    private static func validHeader(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            })
    }

    private static func safeExceptionCode(_ value: String?) -> String? {
        guard let value, (1...6).contains(value.utf8.count),
            value.utf8.allSatisfy({ (48...57).contains($0) }),
            let number = Int(value), number <= 999_999
        else {
            return nil
        }
        return String(number)
    }
}

private final class ClickHouseDatabaseURLSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
