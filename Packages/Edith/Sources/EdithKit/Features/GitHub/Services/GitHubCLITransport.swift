import EdithCore
import Foundation

public struct GitHubAPIRequest: Equatable, Sendable {
    public let host: GitHubHost
    public let endpoint: String
    public let query: [(String, String)]
    public let accept: String
    public let headers: [(String, String)]
    public let maximumOutputBytes: Int

    public init(
        host: GitHubHost, endpoint: String, query: [(String, String)] = [],
        accept: String = "application/vnd.github+json", headers: [(String, String)] = [],
        maximumOutputBytes: Int = 5_000_000
    ) {
        self.host = host
        self.endpoint = endpoint
        self.query = query
        self.accept = accept
        self.headers = headers
        self.maximumOutputBytes = maximumOutputBytes
    }

    public static func == (lhs: GitHubAPIRequest, rhs: GitHubAPIRequest) -> Bool {
        lhs.host == rhs.host && lhs.endpoint == rhs.endpoint
            && lhs.query.elementsEqual(rhs.query) {
                $0 == $1
            } && lhs.accept == rhs.accept
            && lhs.headers.elementsEqual(rhs.headers) {
                $0 == $1
            } && lhs.maximumOutputBytes == rhs.maximumOutputBytes
    }
}

public struct GitHubAPIResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public subscript(header name: String) -> String? { headers[name.lowercased()] }
}

public struct GitHubRateLimit: Equatable, Sendable {
    public let remaining: Int?
    public let limit: Int?
    public let resetAt: Date?
    public let retryAfter: TimeInterval?
    public let resource: String?

    public init(response: GitHubAPIResponse) {
        remaining = response[header: "x-ratelimit-remaining"].flatMap(Int.init)
        limit = response[header: "x-ratelimit-limit"].flatMap(Int.init)
        resetAt = response[header: "x-ratelimit-reset"].flatMap(TimeInterval.init).map {
            Date(timeIntervalSince1970: $0)
        }
        retryAfter = response[header: "retry-after"].flatMap(TimeInterval.init)
        resource = response[header: "x-ratelimit-resource"]
    }
}

public struct GitHubCLITransport: Sendable {
    public typealias RunCommand =
        @Sendable (CLICommandRequest) async throws -> CLICommandCapturedResult

    private let executableURL: URL?
    private let environment: [String: String]
    private let runCommand: RunCommand

    public init(
        executableURL: URL? = CLIToolEnvironment.executable(named: "gh"),
        environment: [String: String] = CLIToolEnvironment.sanitized(),
        runCommand: @escaping RunCommand = { try await CLICommandRunner.runCaptured($0) }
    ) {
        self.executableURL = executableURL
        self.environment = environment
        self.runCommand = runCommand
    }

    public func send(_ request: GitHubAPIRequest) async throws -> GitHubAPIResponse {
        guard let executableURL else { throw GitHubRepositoryLoadError.cliUnavailable }
        let hostname = request.host.port.map { "\(request.host.name):\($0)" } ?? request.host.name
        var arguments = [
            "api", "--include", "--hostname", hostname, "--method", "GET", "-H",
            "Accept: \(request.accept)",
        ]
        if request.host.name == GitHubHost.github.name {
            arguments += ["-H", "X-GitHub-Api-Version: 2022-11-28"]
        }
        for header in request.headers {
            arguments += ["-H", "\(header.0): \(header.1)"]
        }
        arguments.append(request.endpoint)
        for item in request.query {
            arguments += ["--raw-field", "\(item.0)=\(item.1)"]
        }
        let result = try await runCommand(
            CLICommandRequest(
                executableURL: executableURL, arguments: arguments, environment: environment,
                timeout: 25, maximumOutputBytes: request.maximumOutputBytes,
                terminatesProcessGroup: true))
        let response: GitHubAPIResponse
        do {
            response = try Self.parse(result.standardOutputData)
        } catch {
            if result.terminationStatus != 0 {
                throw Self.commandError(result.standardError)
            }
            throw GitHubRepositoryLoadError.invalidResponse(
                "GitHub returned a response that Edith could not read.")
        }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 304 else {
            throw Self.responseError(response, diagnostic: result.standardError)
        }
        if result.terminationStatus != 0, response.statusCode != 304 {
            throw Self.commandError(result.standardError)
        }
        return response
    }

    public static func parse(_ data: Data) throws -> GitHubAPIResponse {
        guard let boundary = headerBoundary(in: data),
            let headerText = String(data: data[..<boundary.lowerBound], encoding: .utf8)
        else {
            throw GitHubRepositoryLoadError.invalidResponse("Missing GitHub response headers.")
        }
        let lines = headerText.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        guard let statusLine = lines.first,
            let statusCode = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else {
            throw GitHubRepositoryLoadError.invalidResponse("Missing GitHub response status.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return GitHubAPIResponse(
            statusCode: statusCode, headers: headers,
            body: Data(data[boundary.upperBound...]))
    }

    public static func endpoint(
        repository: GitHubRepositoryPath, suffix: [String] = []
    ) -> String {
        (["repos", repository.owner, repository.name] + suffix)
            .map(encodedPathSegment).joined(separator: "/")
    }

    private static func headerBoundary(in data: Data) -> Range<Data.Index>? {
        data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8))
    }

    private static func encodedPathSegment(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func commandError(_ diagnostic: String) -> GitHubRepositoryLoadError {
        let message = sanitized(diagnostic)
        let lower = message.lowercased()
        if lower.contains("authentication") || lower.contains("not logged") {
            return .authenticationRequired(message)
        }
        if lower.contains("could not resolve host") || lower.contains("network") {
            return .offline(message)
        }
        return .commandFailed(message.isEmpty ? "The GitHub command failed." : message)
    }

    private static func responseError(
        _ response: GitHubAPIResponse, diagnostic: String
    ) -> GitHubRepositoryLoadError {
        let serverMessage = decodedMessage(response.body)
        let message = serverMessage ?? sanitized(diagnostic)
        switch response.statusCode {
        case 401:
            return .authenticationRequired(message)
        case 403
        where response[header: "retry-after"] != nil
            || response[header: "x-ratelimit-remaining"] == "0":
            return .rateLimited(rateLimitMessage(response))
        case 403:
            return .permissionDenied(message)
        case 404:
            return .notFound(message)
        case 429:
            return .rateLimited(rateLimitMessage(response))
        case 500...599:
            return .offline(message)
        default:
            return .commandFailed(
                message.isEmpty ? "GitHub returned HTTP \(response.statusCode)." : message)
        }
    }

    private static func decodedMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["message"] as? String
    }

    private static func rateLimitMessage(_ response: GitHubAPIResponse) -> String {
        let limit = GitHubRateLimit(response: response)
        if let retryAfter = limit.retryAfter {
            return "GitHub asked Edith to retry in \(Int(retryAfter.rounded(.up))) seconds."
        }
        if let resetAt = limit.resetAt {
            return
                "GitHub API access resets \(resetAt.formatted(date: .omitted, time: .shortened))."
        }
        return "GitHub temporarily limited API requests."
    }

    private static func sanitized(_ value: String) -> String {
        let line = value.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
    }
}
