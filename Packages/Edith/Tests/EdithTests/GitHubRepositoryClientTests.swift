import EdithCore
import Foundation
import Testing

@testable import EdithKit

@Suite struct GitHubRepositoryClientTests {
    @Test func transportParsesCRLFHeadersAndPreservesBinaryBody() throws {
        let body = Data([0x00, 0xFF, 0x0D, 0x0A, 0x01, 0x02])
        var data = Data(
            "HTTP/2.0 200 OK\r\nETag: \"fixture\"\r\nX-RateLimit-Remaining: 42\r\n\r\n".utf8)
        data.append(body)

        let response = try GitHubCLITransport.parse(data)

        #expect(response.statusCode == 200)
        #expect(response[header: "etag"] == "\"fixture\"")
        #expect(response[header: "X-RateLimit-Remaining"] == "42")
        #expect(response.body == body)
    }

    @Test func enterpriseRequestUsesExactArgumentsWithoutPublicAPIVersionHeader() async throws {
        let recorder = GitHubCommandRecorder(
            result: captured(
                status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))
        let executable = URL(fileURLWithPath: "/usr/local/bin/gh")
        let environment = ["PATH": "/usr/bin"]
        let transport = GitHubCLITransport(
            executableURL: executable, environment: environment,
            runCommand: { request in try await recorder.run(request) })
        let host = GitHubHost(scheme: "https", name: "github.example.com")!
        let request = GitHubAPIRequest(
            host: host, endpoint: "repos/acme/orbit/contents/Sources",
            query: [("ref", "feature/navigation")], headers: [("If-None-Match", "\"abc\"")],
            maximumOutputBytes: 1_234)

        _ = try await transport.send(request)
        let command = try #require(await recorder.requests().first)

        #expect(command.executableURL == executable)
        #expect(command.environment == environment)
        #expect(command.timeout == 25)
        #expect(command.maximumOutputBytes == 1_234)
        #expect(command.terminatesProcessGroup)
        #expect(
            command.arguments
                == [
                    "api", "--include", "--hostname", "github.example.com", "--method", "GET",
                    "-H", "Accept: application/vnd.github+json", "-H",
                    "If-None-Match: \"abc\"", "repos/acme/orbit/contents/Sources", "--raw-field",
                    "ref=feature/navigation",
                ])
        #expect(!command.arguments.contains("X-GitHub-Api-Version: 2022-11-28"))
    }

    @Test func transportMapsNotFoundResponse() async throws {
        let transport = transport(
            status: 404, headers: ["Content-Type": "application/json"],
            body: Data(#"{"message":"repository missing"}"#.utf8), terminationStatus: 1)

        do {
            _ = try await transport.send(request())
            Issue.record("Expected a not-found error")
        } catch let error as GitHubRepositoryLoadError {
            #expect(error == .notFound("repository missing"))
        }
    }

    @Test func transportMapsRateLimitResponseAndParsesRetryMetadata() async throws {
        let headers = [
            "Content-Type": "application/json", "Retry-After": "2.2",
            "X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset": "1788042832", "X-RateLimit-Resource": "core",
        ]
        let transport = transport(
            status: 403, headers: headers,
            body: Data(#"{"message":"API rate limit exceeded"}"#.utf8), terminationStatus: 1)

        do {
            _ = try await transport.send(request())
            Issue.record("Expected a rate-limit error")
        } catch let error as GitHubRepositoryLoadError {
            #expect(
                error
                    == .rateLimited("GitHub asked Edith to retry in 3 seconds."))
        }

        let response = GitHubAPIResponse(
            statusCode: 403,
            headers: Dictionary(
                uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }),
            body: Data())
        let rateLimit = GitHubRateLimit(response: response)
        #expect(rateLimit.remaining == 0)
        #expect(rateLimit.limit == 5_000)
        #expect(rateLimit.retryAfter == 2.2)
        #expect(rateLimit.resetAt == Date(timeIntervalSince1970: 1_788_042_832))
        #expect(rateLimit.resource == "core")
    }

    @Test func repositoryFixtureDecodesOverviewAndUsesBoundedRequestSequence() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(
                #"""
                {
                  "description": "Native desktop tools",
                  "private": false,
                  "fork": true,
                  "archived": false,
                  "default_branch": "main",
                  "stargazers_count": 91,
                  "forks_count": 12,
                  "open_issues_count": 7,
                  "language": "Swift",
                  "license": {"spdx_id": "MIT"},
                  "topics": ["macos", "swiftui"],
                  "updated_at": "2026-08-29T20:30:00Z",
                  "html_url": "https://github.com/acme/orbit",
                  "additive_field": {"future": true}
                }
                """#),
            response(
                #"""
                [
                  {"name":"main","commit":{"sha":"1111111"}},
                  {"name":"feature/navigation","commit":{"sha":"2222222"}}
                ]
                """#),
            response(
                #"""
                [
                  {
                    "sha":"abcdef1234567890",
                    "commit":{
                      "message":"Ship browser\n\nDetails",
                      "author":{"name":"Ada","date":"2026-08-29T19:00:00Z"}
                    },
                    "author":{"login":"ada"},
                    "html_url":"https://github.com/acme/orbit/commit/abcdef1234567890"
                  }
                ]
                """#),
            response(
                #"""
                {
                  "entries": [
                    {"name":"README.md","path":"README.md","sha":"b2","size":80,"type":"file","html_url":"https://github.com/acme/orbit/blob/main/README.md"},
                    {"name":"Sources","path":"Sources","sha":"a1","size":0,"type":"dir","html_url":"https://github.com/acme/orbit/tree/main/Sources"}
                  ]
                }
                """#),
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })

        let resource = try await client.load(repositoryRoute)
        let overview = try #require(resource.repository)

        #expect(overview.repository == repository)
        #expect(overview.description == "Native desktop tools")
        #expect(!overview.isPrivate)
        #expect(overview.isFork)
        #expect(!overview.isArchived)
        #expect(overview.defaultBranch == "main")
        #expect(overview.stars == 91)
        #expect(overview.forks == 12)
        #expect(overview.openIssues == 7)
        #expect(overview.language == "Swift")
        #expect(overview.license == "MIT")
        #expect(overview.topics == ["macos", "swiftui"])
        #expect(overview.updatedAt != nil)
        #expect(overview.url.absoluteString == "https://github.com/acme/orbit")
        #expect(overview.branches.map(\.name) == ["main", "feature/navigation"])
        #expect(overview.latestCommit?.shortSHA == "abcdef1")
        #expect(overview.latestCommit?.subject == "Ship browser")
        #expect(overview.latestCommit?.authorLogin == "ada")
        #expect(
            overview.latestCommit?.url?.absoluteString
                == "https://github.com/acme/orbit/commit/abcdef1234567890")
        #expect(overview.entries.map(\.name) == ["Sources", "README.md"])
        #expect(
            overview.entries[0].url?.absoluteString
                == "https://github.com/acme/orbit/tree/main/Sources")

        let requests = await fixture.requests()
        #expect(requests.count == 4)
        #expect(requests[0] == request(endpoint: "repos/acme/orbit"))
        #expect(
            requests[1]
                == request(endpoint: "repos/acme/orbit/branches", query: [("per_page", "40")]))
        #expect(
            requests[2]
                == request(
                    endpoint: "repos/acme/orbit/commits",
                    query: [("sha", "main"), ("per_page", "1")]))
        #expect(
            requests[3]
                == request(
                    endpoint: "repos/acme/orbit/contents", query: [("ref", "main")],
                    accept: "application/vnd.github.object+json"))
    }

    @Test func emptyRepositoryReturnsAnEmptyOverview() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(
                #"""
                {
                  "description": null,
                  "private": false,
                  "fork": false,
                  "archived": false,
                  "default_branch": "main",
                  "stargazers_count": 0,
                  "forks_count": 0,
                  "open_issues_count": 0,
                  "language": null,
                  "license": null,
                  "topics": [],
                  "updated_at": "2026-08-30T00:00:00Z",
                  "html_url": "https://github.com/acme/orbit"
                }
                """#),
            response("[]"),
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })

        let resource = try await client.load(repositoryRoute)
        let overview = try #require(resource.repository)

        #expect(overview.branches.isEmpty)
        #expect(overview.latestCommit == nil)
        #expect(overview.entries.isEmpty)
        #expect(
            await fixture.requests()
                == [
                    request(),
                    request(
                        endpoint: "repos/acme/orbit/branches", query: [("per_page", "40")]),
                ])
    }

    @Test func nestedDirectorySortsFoldersFirstAndPreservesUnknownKinds() async throws {
        let fixture = GitHubRequestFixture(
            responses: mainReferenceResponses + [
                response(
                    #"""
                    [
                      {"name":"cc-file","path":"Sources/Deep/cc-file","sha":"5","size":9,"type":"file"},
                      {"name":"z-dir","path":"Sources/Deep/z-dir","sha":"2","size":0,"type":"dir"},
                      {"name":"aa-unknown","path":"Sources/Deep/aa-unknown","sha":"3","size":0,"type":"future-kind"},
                      {"name":"A-dir","path":"Sources/Deep/A-dir","sha":"1","size":0,"type":"dir"},
                      {"name":"bb-link","path":"Sources/Deep/bb-link","sha":"4","size":0,"type":"symlink"}
                    ]
                    """#)
            ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .tree,
                revisionPath: ["main", "Sources", "Deep"], view: .automatic, lines: nil))

        let resource = try await client.load(route)
        let directory = try #require(resource.directory)

        #expect(directory.path == "Sources/Deep")
        #expect(
            directory.entries.map(\.name) == ["A-dir", "z-dir", "aa-unknown", "bb-link", "cc-file"])
        #expect(directory.entries[2].kind.rawValue == "future-kind")
        #expect(
            await fixture.requests()
                == referenceRequests + [
                    request(
                        endpoint: "repos/acme/orbit/contents/Sources/Deep",
                        query: [("ref", "main")],
                        accept: "application/vnd.github.object+json")
                ])
    }

    @Test func slashBranchUsesTheLongestMatchingReference() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(#"[{"name":"feature"},{"name":"feature/navigation"}]"#),
            response(#"[{"name":"feature/navigation/archive"}]"#),
            response(
                #"""
                [
                  {"name":"App.swift","path":"Sources/App.swift","sha":"swift","size":42,"type":"file"}
                ]
                """#),
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .tree,
                revisionPath: ["feature", "navigation", "Sources"], view: .automatic,
                lines: nil))

        let resource = try await client.load(route)
        let directory = try #require(resource.directory)

        #expect(directory.revision == "feature/navigation")
        #expect(directory.path == "Sources")
        #expect(
            await fixture.requests()
                == referenceRequests + [
                    request(
                        endpoint: "repos/acme/orbit/contents/Sources",
                        query: [("ref", "feature/navigation")],
                        accept: "application/vnd.github.object+json")
                ])
    }

    @Test func slashTagResolvesBeforeLoadingAFile() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(#"[{"name":"release"}]"#),
            response(#"[{"name":"release/v2"}]"#),
            response(
                #"""
                {
                  "name":"README.md",
                  "path":"README.md",
                  "sha":"readme",
                  "size":6,
                  "type":"file",
                  "encoding":"base64",
                  "content":"aGVsbG8K"
                }
                """#),
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: ["release", "v2", "README.md"], view: .automatic, lines: nil))

        let resource = try await client.load(route)
        let file = try #require(resource.file)

        #expect(file.revision == "release/v2")
        #expect(file.path == "README.md")
        #expect(file.text == "hello\n")
        #expect(
            await fixture.requests()
                == referenceRequests + [
                    request(
                        endpoint: "repos/acme/orbit/contents/README.md",
                        query: [("ref", "release/v2")],
                        accept: "application/vnd.github.object+json", maximumOutputBytes: 6_000_000)
                ])
    }

    @Test func unresolvedSingleSegmentReferenceFallsBackForCommitSHAs() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(
                #"""
                {
                  "name":"README.md",
                  "path":"README.md",
                  "sha":"readme",
                  "size":6,
                  "type":"file",
                  "encoding":"base64",
                  "content":"aGVsbG8K"
                }
                """#)
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: ["abcdef123456", "README.md"], view: .automatic, lines: nil))

        let resource = try await client.load(route)
        let file = try #require(resource.file)

        #expect(file.revision == "abcdef123456")
        #expect(file.path == "README.md")
        #expect(
            await fixture.requests()
                == [
                    request(
                        endpoint: "repos/acme/orbit/contents/README.md",
                        query: [("ref", "abcdef123456")],
                        accept: "application/vnd.github.object+json", maximumOutputBytes: 6_000_000)
                ])
    }

    @Test func referenceDiscoveryStopsAfterTheLimitedInitialPage() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(referenceNames(100)),
            response("[]"),
            response(
                #"{"name":"README.md","path":"README.md","sha":"readme","size":6,"type":"file","encoding":"base64","content":"aGVsbG8K"}"#
            ),
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: ["missing", "README.md"], view: .automatic, lines: nil))

        let resource = try await client.load(route)
        let file = try #require(resource.file)

        #expect(file.revision == "missing")
        #expect(
            await fixture.requests()
                == referenceRequests + [
                    request(
                        endpoint: "repos/acme/orbit/contents/README.md",
                        query: [("ref", "missing")], accept: "application/vnd.github.object+json",
                        maximumOutputBytes: 6_000_000)
                ])
    }

    @Test func resolvedContentIdentityBypassesAmbiguousReferenceLookup() async throws {
        let fixture = GitHubRequestFixture(responses: [
            response(
                #"{"name":"Guide.md","path":"v2/Guide.md","sha":"guide","size":6,"type":"file","encoding":"base64","content":"aGVsbG8K"}"#
            )
        ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })
        let location = try #require(
            GitHubResolvedContentPath(revision: "release", path: ["v2", "Guide.md"]))
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: ["release", "v2", "Guide.md"], view: .automatic, lines: nil),
            resolvedContentPath: location)

        let resource = try await client.load(route)
        let file = try #require(resource.file)

        #expect(file.revision == "release")
        #expect(file.path == "v2/Guide.md")
        #expect(
            await fixture.requests()
                == [
                    request(
                        endpoint: "repos/acme/orbit/contents/v2/Guide.md",
                        query: [("ref", "release")], accept: "application/vnd.github.object+json",
                        maximumOutputBytes: 6_000_000)
                ])
    }

    @Test func filesDecodeBase64TextAndExposeLargeFileState() async throws {
        let fixture = GitHubRequestFixture(
            responses: mainReferenceResponses + [
                response(
                    #"""
                    {
                      "name":"README.md",
                      "path":"README.md",
                      "sha":"text-sha",
                      "size":11,
                      "type":"file",
                      "download_url":"https://raw.githubusercontent.com/acme/orbit/main/README.md",
                      "encoding":"base64",
                      "content":"YWxw\naGEKYmV0YQo="
                    }
                    """#),
                response(
                    #"""
                    {
                      "name":"archive.data",
                      "path":"Assets/archive.data",
                      "sha":"large-sha",
                      "size":4000001,
                      "type":"file",
                      "download_url":"https://raw.githubusercontent.com/acme/orbit/main/Assets/archive.data",
                      "encoding":"none",
                      "content":null
                    }
                    """#),
            ])
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in try await fixture.send(request) })

        let textResource = try await client.load(fileRoute("README.md"))
        let text = try #require(textResource.file)
        #expect(text.presentation == .text)
        #expect(text.text == "alpha\nbeta\n")
        #expect(text.lines == ["alpha", "beta", ""])
        #expect(
            text.downloadURL?.absoluteString
                == "https://raw.githubusercontent.com/acme/orbit/main/README.md")

        let largeResource = try await client.load(fileRoute("Assets/archive.data"))
        let large = try #require(largeResource.file)
        #expect(large.presentation == .large)
        #expect(large.text == nil)
        #expect(large.size == 4_000_001)

        let requests = await fixture.requests()
        #expect(requests.count == 4)
        #expect(requests.suffix(2).allSatisfy { $0.maximumOutputBytes == 6_000_000 })
    }

    @Test func persistedCacheRestoresResourceWithoutAnotherRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheFile = root.appendingPathComponent("nested/resources.json")
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .tree, revisionPath: ["main", "Sources"],
                view: .automatic, lines: nil))
        let fixture = GitHubRequestFixture(
            responses: mainReferenceResponses + [
                response(
                    #"""
                    [
                      {"name":"App.swift","path":"Sources/App.swift","sha":"swift","size":42,"type":"file"}
                    ]
                    """#)
            ])
        let first = GitHubRepositoryClient(
            cacheFile: cacheFile, sendRequest: { request in try await fixture.send(request) })

        let loaded = try await first.load(route)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))

        let unexpected = GitHubRequestFixture(responses: [])
        let restored = GitHubRepositoryClient(
            cacheFile: cacheFile, sendRequest: { request in try await unexpected.send(request) })
        let cached = await restored.cachedResource(for: route)

        #expect(cached == loaded)
        #expect(await unexpected.requests().isEmpty)
    }

    @Test func cancelledLoadCannotCacheALateResponse() async throws {
        let fixture = GitHubBlockingRequestFixture()
        let client = GitHubRepositoryClient(
            cacheFile: nil, sendRequest: { request in await fixture.send(request) })
        let route = GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .tree, revisionPath: ["main", "Sources"],
                view: .automatic, lines: nil))
        let task = Task { try await client.load(route) }
        await fixture.waitUntilStarted()

        task.cancel()
        await fixture.release(
            response(
                #"""
                [
                  {"name":"Late.swift","path":"Sources/Late.swift","sha":"late","size":1,"type":"file"}
                ]
                """#))

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        }
        #expect(await client.cachedResource(for: route) == nil)
    }

    private var repository: GitHubRepositoryPath {
        GitHubRepositoryPath(owner: "acme", name: "orbit")!
    }

    private var repositoryRoute: GitHubRoute {
        GitHubRoute(host: .github, resource: .repository(repository))
    }

    private var mainReferenceResponses: [GitHubAPIResponse] {
        [response(#"[{"name":"main"}]"#), response("[]")]
    }

    private var referenceRequests: [GitHubAPIRequest] {
        [
            request(endpoint: "repos/acme/orbit/branches", query: [("per_page", "100")]),
            request(endpoint: "repos/acme/orbit/tags", query: [("per_page", "100")]),
        ]
    }

    private func referenceNames(_ count: Int) -> String {
        "[" + (0..<count).map { #"{"name":"branch-\#($0)"}"# }.joined(separator: ",") + "]"
    }

    private func fileRoute(_ path: String) -> GitHubRoute {
        GitHubRoute(
            host: .github,
            resource: .content(
                repository: repository, kind: .blob,
                revisionPath: ["main"] + path.split(separator: "/").map(String.init),
                view: .automatic, lines: nil))
    }

    private func request(
        endpoint: String = "repos/acme/orbit", query: [(String, String)] = [],
        accept: String = "application/vnd.github+json", maximumOutputBytes: Int = 5_000_000
    ) -> GitHubAPIRequest {
        GitHubAPIRequest(
            host: .github, endpoint: endpoint, query: query, accept: accept,
            maximumOutputBytes: maximumOutputBytes)
    }

    private func response(_ value: String) -> GitHubAPIResponse {
        GitHubAPIResponse(statusCode: 200, headers: [:], body: Data(value.utf8))
    }

    private func transport(
        status: Int, headers: [String: String], body: Data, terminationStatus: Int32
    ) -> GitHubCLITransport {
        GitHubCLITransport(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/gh"), environment: [:]
        ) { _ in
            captured(
                status: status, headers: headers, body: body,
                terminationStatus: terminationStatus)
        }
    }

    private func captured(
        status: Int, headers: [String: String], body: Data, terminationStatus: Int32 = 0
    ) -> CLICommandCapturedResult {
        var output = Data("HTTP/2.0 \(status) Fixture\r\n".utf8)
        for header in headers.sorted(by: { $0.key < $1.key }) {
            output.append(Data("\(header.key): \(header.value)\r\n".utf8))
        }
        output.append(Data("\r\n".utf8))
        output.append(body)
        return CLICommandCapturedResult(
            terminationStatus: terminationStatus, standardOutputData: output,
            standardErrorData: Data())
    }
}

private extension GitHubRepositoryResource {
    var repository: GitHubRepositoryOverview? {
        guard case let .repository(value) = self else { return nil }
        return value
    }

    var directory: GitHubDirectorySnapshot? {
        guard case let .directory(value) = self else { return nil }
        return value
    }

    var file: GitHubFileSnapshot? {
        guard case let .file(value) = self else { return nil }
        return value
    }
}

private actor GitHubCommandRecorder {
    private var recorded: [CLICommandRequest] = []
    private let result: CLICommandCapturedResult

    init(result: CLICommandCapturedResult) {
        self.result = result
    }

    func run(_ request: CLICommandRequest) throws -> CLICommandCapturedResult {
        recorded.append(request)
        return result
    }

    func requests() -> [CLICommandRequest] {
        recorded
    }
}

private actor GitHubRequestFixture {
    private var recorded: [GitHubAPIRequest] = []
    private var responses: [GitHubAPIResponse]

    init(responses: [GitHubAPIResponse]) {
        self.responses = responses
    }

    func send(_ request: GitHubAPIRequest) throws -> GitHubAPIResponse {
        recorded.append(request)
        guard !responses.isEmpty else {
            throw GitHubRepositoryLoadError.commandFailed("Missing fixture response.")
        }
        return responses.removeFirst()
    }

    func requests() -> [GitHubAPIRequest] {
        recorded
    }
}

private actor GitHubBlockingRequestFixture {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiter: CheckedContinuation<GitHubAPIResponse, Never>?

    func send(_ request: GitHubAPIRequest) async -> GitHubAPIResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { responseWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ response: GitHubAPIResponse) {
        responseWaiter?.resume(returning: response)
        responseWaiter = nil
    }
}
