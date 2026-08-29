import Foundation
import Testing

@testable import EdithCore

@Suite struct GitHubRouteTests {
    @Test func parsesRepositoryAndContentRoutes() throws {
        let repository = try route("https://github.com/pulkitxm/edith")
        let tree = try route("https://github.com/pulkitxm/edith/tree/main/Packages/Edith")
        let blob = try route(
            "https://github.com/pulkitxm/edith/blob/main/README.md?plain=1#L10-L15")

        #expect(repository.resource == .repository(repo))
        #expect(
            tree.resource
                == .content(
                    repository: repo, kind: .tree,
                    revisionPath: ["main", "Packages", "Edith"], view: .automatic, lines: nil))
        #expect(
            blob.resource
                == .content(
                    repository: repo, kind: .blob, revisionPath: ["main", "README.md"],
                    view: .code, lines: .range(10...15)))
        #expect(
            blob.url.absoluteString
                == "https://github.com/pulkitxm/edith/blob/main/README.md?plain=1#L10-L15")
    }

    @Test func preservesAnUnresolvedSlashContainingRevisionPath() throws {
        let parsed = try route(
            "https://github.com/acme/orbit/blob/feature/navigation/Sources/App.swift#L8")

        #expect(
            parsed.resource
                == .content(
                    repository: orbit, kind: .blob,
                    revisionPath: ["feature", "navigation", "Sources", "App.swift"],
                    view: .automatic, lines: .single(8)))
        #expect(
            parsed.url.absoluteString
                == "https://github.com/acme/orbit/blob/feature/navigation/Sources/App.swift#L8")
    }

    @Test func persistsResolvedContentIdentityWithoutChangingItsURL() throws {
        let location = try #require(
            GitHubResolvedContentPath(
                revision: "release", path: ["v2", "Sources", "App.swift"]))
        let resolved = GitHubRoute(
            host: .github,
            resource: .content(
                repository: orbit, kind: .blob,
                revisionPath: ["release", "v2", "Sources", "App.swift"], view: .automatic,
                lines: nil),
            resolvedContentPath: location)
        let decoded = try JSONDecoder().decode(
            GitHubRoute.self, from: JSONEncoder().encode(resolved))

        #expect(
            resolved.url.absoluteString
                == "https://github.com/acme/orbit/blob/release/v2/Sources/App.swift")
        #expect(decoded == resolved)
        #expect(GitHubRoute(url: resolved.url)?.resolvedContentPath == nil)
    }

    @Test func parsesRepositoryCollectionsAndDetails() throws {
        #expect(try route("https://github.com/acme/orbit/branches").resource == .branches(orbit))
        #expect(try route("https://github.com/acme/orbit/tags").resource == .tags(orbit))
        #expect(
            try route("https://github.com/acme/orbit/commits/main/Sources").resource
                == .commits(repository: orbit, revision: "main", path: ["Sources"]))
        #expect(
            try route("https://github.com/acme/orbit/commit/abcdef1").resource
                == .commit(repository: orbit, oid: "abcdef1"))
        #expect(
            try route("https://github.com/acme/orbit/compare/main...feature").resource
                == .comparison(repository: orbit, expression: "main...feature"))
    }

    @Test func parsesPullIssueActionAndProjectRoutes() throws {
        #expect(
            try route("https://github.com/acme/orbit/pulls?q=is%3Aopen").resource
                == .pullRequests(
                    repository: orbit, query: [GitHubQuery(name: "q", value: "is:open")]))
        #expect(
            try route("https://github.com/acme/orbit/pull/42").resource
                == .pullRequest(repository: orbit, number: 42))
        #expect(
            try route("https://github.com/acme/orbit/issues/9").resource
                == .issue(repository: orbit, number: 9))
        #expect(
            try route("https://github.com/acme/orbit/actions/runs/123").resource
                == .workflowRun(repository: orbit, id: 123))
        #expect(
            try route("https://github.com/orgs/acme/projects/7").resource
                == .organizationProject(organization: "acme", number: 7))
    }

    @Test func supportsEnterpriseHostsAndEncodedPaths() throws {
        let parsed = try route(
            "https://git.acme.test/acme/orbit/blob/main/Docs/Hello%20World.md")

        #expect(parsed.host == GitHubHost(scheme: "https", name: "git.acme.test"))
        #expect(
            parsed.resource
                == .content(
                    repository: orbit, kind: .blob,
                    revisionPath: ["main", "Docs", "Hello World.md"],
                    view: .automatic, lines: nil))
        #expect(
            parsed.url.absoluteString
                == "https://git.acme.test/acme/orbit/blob/main/Docs/Hello%20World.md")
    }

    @Test func rejectsHostsUnsupportedByTheGitHubCLITransport() throws {
        #expect(GitHubHost(scheme: "http", name: "git.acme.test") == nil)
        #expect(GitHubHost(scheme: "https", name: "git.acme.test", port: 8443) == nil)
        #expect(GitHubRoute(url: URL(string: "http://git.acme.test/acme/orbit")!) == nil)
        #expect(GitHubRoute(url: URL(string: "https://git.acme.test:8443/acme/orbit")!) == nil)

        let defaultPort = try #require(
            GitHubRoute(url: URL(string: "https://git.acme.test:443/acme/orbit")!))
        #expect(defaultPort.host.port == nil)
        #expect(defaultPort.url.absoluteString == "https://git.acme.test/acme/orbit")
    }

    @Test func decodingRevalidatesAndCanonicalizesStoredHosts() throws {
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                GitHubHost.self,
                from: Data(#"{"scheme":"http","name":"git.acme.test","port":null}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(
                GitHubHost.self,
                from: Data(#"{"scheme":"https","name":"git.acme.test","port":8443}"#.utf8))
        }

        let canonical = try decoder.decode(
            GitHubHost.self,
            from: Data(#"{"scheme":"https","name":"git.acme.test","port":443}"#.utf8))
        #expect(canonical.port == nil)
    }

    @Test func lineFragmentsRejectInvalidRanges() {
        #expect(GitHubLineSelection(fragment: "L1") == .single(1))
        #expect(GitHubLineSelection(fragment: "L2-L5") == .range(2...5))
        #expect(GitHubLineSelection(fragment: "L0") == nil)
        #expect(GitHubLineSelection(fragment: "L9-L2") == nil)
        #expect(GitHubLineSelection(fragment: "section") == nil)
    }

    @Test func everyRouteRoundTripsThroughJSONAndURL() throws {
        let urls = [
            "https://github.com/", "https://github.com/search?q=edith&type=repositories",
            "https://github.com/pulkitxm", "https://github.com/orgs/acme",
            "https://github.com/acme/orbit", "https://github.com/acme/orbit/tree/main/Sources",
            "https://github.com/acme/orbit/raw/main/icon.png",
            "https://github.com/acme/orbit/blame/main/README.md#L3",
            "https://github.com/acme/orbit/pulls", "https://github.com/acme/orbit/issues",
            "https://github.com/acme/orbit/actions", "https://github.com/acme/orbit/projects/3",
            "https://github.com/acme/orbit/settings/branches",
            "https://github.com/settings/profile",
            "https://github.com/acme/orbit/discussions/12",
        ]

        for value in urls {
            let parsed = try route(value)
            let decoded = try JSONDecoder().decode(
                GitHubRoute.self, from: JSONEncoder().encode(parsed))
            #expect(decoded == parsed)
            #expect(GitHubRoute(url: parsed.url) == parsed)
        }
    }

    @Test func classifiesNativeAndFallbackResources() throws {
        #expect(try route("https://github.com/acme/orbit").support == .fullyNative)
        #expect(try route("https://github.com/acme/orbit/pull/2").support == .nativeReadOnly)
        #expect(
            try route("https://github.com/acme/orbit/settings").support == .opensOnGitHub)
        #expect(
            try route("https://github.com/acme/orbit/discussions/2").support == .unavailable)
    }

    private var repo: GitHubRepositoryPath {
        GitHubRepositoryPath(owner: "pulkitxm", name: "edith")!
    }

    private var orbit: GitHubRepositoryPath {
        GitHubRepositoryPath(owner: "acme", name: "orbit")!
    }

    private func route(_ value: String) throws -> GitHubRoute {
        let url = try #require(URL(string: value))
        return try #require(GitHubRoute(url: url))
    }
}
