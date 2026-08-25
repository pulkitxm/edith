import Foundation
import Testing
@testable import EdithHelper

private final class ClaudeShellInvocationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedInvocation: ClaudeShellInvocation?
    private var storedMainThread = true

    func record(_ invocation: ClaudeShellInvocation) {
        lock.lock()
        storedInvocation = invocation
        storedMainThread = Thread.isMainThread
        lock.unlock()
    }

    func snapshot() -> (ClaudeShellInvocation?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storedInvocation, storedMainThread)
    }
}

private final class ClaudeShellCredentialQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private var storedCalls = 0

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func next() -> ClaudeShellCredentialResolution {
        lock.lock()
        defer { lock.unlock() }
        storedCalls += 1
        guard !tokens.isEmpty,
            let credential = ClaudeOAuthCredential.transient(accessToken: tokens.removeFirst())
        else { return .missing }
        return .credential(credential)
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }
}

@Suite struct ClaudeOAuthCredentialTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func detectsAccessTokenNearExpiry() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(30),
            refreshExpiresAt: now.addingTimeInterval(3_600))
        #expect(credential.shouldRefresh(at: now))
    }

    @Test func keepsAccessTokenWithTimeRemaining() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(600),
            refreshExpiresAt: now.addingTimeInterval(3_600))
        #expect(!credential.shouldRefresh(at: now))
    }

    @Test func rejectsExpiredRefreshToken() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(-1),
            refreshExpiresAt: now.addingTimeInterval(-1))
        #expect(credential.usableRefreshToken(at: now) == nil)
    }

    @Test func savesRotatedTokensAndPreservesOtherCredentials() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(-1),
            refreshExpiresAt: now.addingTimeInterval(60))
        let response = ClaudeOAuthRefreshResponse(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresIn: 600,
            refreshTokenExpiresIn: 3_600)
        let data = try credential.updatedData(with: response, now: now)
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(document["claudeAiOauth"] as? [String: Any])
        let mcp = try #require(document["mcpOAuth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new-access")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Int64 == 1_800_000_600_000)
        #expect(oauth["refreshTokenExpiresAt"] as? Int64 == 1_800_003_600_000)
        #expect(mcp["preserved"] as? Bool == true)
    }

    @Test func transientTokensStayMemoryOnly() throws {
        let credential = try #require(
            ClaudeOAuthCredential.transient(accessToken: "shell-access"))
        #expect(credential.source == .shell)
        #expect(credential.refreshToken == nil)
        #expect(credential.expiresAt == nil)
        #expect(throws: ClaudeCredentialStoreError.self) {
            try ClaudeCredentialStore.persist(Data("secret".utf8), source: .shell)
        }
    }

    @Test func transientTokensRejectWhitespaceControlsAndOversizedValues() {
        #expect(ClaudeOAuthCredential.transient(accessToken: "") == nil)
        #expect(ClaudeOAuthCredential.transient(accessToken: "two words") == nil)
        #expect(ClaudeOAuthCredential.transient(accessToken: "line\nbreak") == nil)
        #expect(
            ClaudeOAuthCredential.transient(
                accessToken: String(repeating: "x", count: 9), maximumBytes: 8) == nil)
    }

    private func decode(accessExpiresAt: Date, refreshExpiresAt: Date) throws
        -> ClaudeOAuthCredential
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "mcpOAuth": ["preserved": true],
            "claudeAiOauth": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": Int64(accessExpiresAt.timeIntervalSince1970 * 1_000),
                "refreshTokenExpiresAt": Int64(refreshExpiresAt.timeIntervalSince1970 * 1_000),
            ],
        ])
        return try #require(ClaudeOAuthCredential.decode(data, source: .keychain))
    }
}

@Suite struct ClaudeShellCredentialResolverTests {
    private let marker = "test-marker"
    private let home = URL(fileURLWithPath: "/tmp")
    private let shell = URL(fileURLWithPath: "/bin/zsh")

    @Test @MainActor func resolvesOffMainWithoutPuttingSecretsInArgumentsOrEnvironment()
        async
        throws
    {
        let capture = ClaudeShellInvocationCapture()
        let token = "shell-access-token"
        let resolver = makeResolver { invocation, _, _ in
            capture.record(invocation)
            return .output(self.framed(token))
        }

        let resolution = await resolver.resolve()
        guard case .credential(let credential) = resolution else {
            Issue.record("expected a credential")
            return
        }
        let (invocation, ranOnMainThread) = capture.snapshot()
        let resolvedInvocation = try #require(invocation)
        #expect(credential.accessToken == token)
        #expect(credential.source == .shell)
        #expect(!ranOnMainThread)
        #expect(!resolvedInvocation.arguments.joined().contains(token))
        #expect(!resolvedInvocation.environment.values.joined().contains(token))
        #expect(
            Set(resolvedInvocation.environment.keys)
                == ["HOME", "LANG", "LOGNAME", "PATH", "SHELL", "USER"])
        #expect(resolvedInvocation.currentDirectory == home)
    }

    @Test func rejectsMalformedAndAmbiguousOutput() async {
        await expectMalformed(Data("shell startup noise".utf8))
        await expectMalformed(framed("two words"))
        await expectMalformed(framed("first") + framed("second"))
        await expectMalformed(Data([0xFF]))
    }

    @Test func distinguishesMissingTimeoutOversizeAndLaunchFailure() async {
        await expect(.missing, from: .output(framed("")))
        await expect(.timedOut, from: .timedOut)
        await expect(.oversized, from: .oversized)
        await expect(.failed, from: .failed)
    }

    @Test func liveRunnerBoundsTimeAndOutput() async {
        let environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        let timeout = await ClaudeShellProcessRunner.run(
            ClaudeShellInvocation(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 2"],
                environment: environment,
                currentDirectory: home),
            timeout: 0.05,
            maximumOutputBytes: 1_024)
        let oversized = await ClaudeShellProcessRunner.run(
            ClaudeShellInvocation(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c 4096 /dev/zero | tr '\\0' x"],
                environment: environment,
                currentDirectory: home),
            timeout: 2,
            maximumOutputBytes: 1_024)
        #expect(timeout == .timedOut)
        #expect(oversized == .oversized)
    }

    @Test func liveLoginShellReadsTheExportedCredential() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-claude-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = Data(
            "printf startup-noise >&2\nexport CLAUDE_CODE_OAUTH_TOKEN=fixture-token\n".utf8
        )
        try profile.write(to: directory.appendingPathComponent(".zshrc"))
        let resolver = ClaudeShellCredentialResolver(
            shell: shell,
            home: directory,
            username: "tester",
            timeout: 2,
            maximumOutputBytes: 4_096,
            marker: marker)

        let resolution = await resolver.resolve()
        guard case .credential(let credential) = resolution else {
            Issue.record("expected a credential")
            return
        }
        #expect(credential.accessToken == "fixture-token")
        #expect(credential.source == .shell)
    }

    private enum ExpectedResolution {
        case missing
        case timedOut
        case oversized
        case failed
    }

    private func makeResolver(
        runner: @escaping ClaudeShellCredentialResolver.Runner
    ) -> ClaudeShellCredentialResolver {
        ClaudeShellCredentialResolver(
            shell: shell,
            home: home,
            username: "tester",
            timeout: 0.1,
            maximumOutputBytes: 1_024,
            marker: marker,
            runner: runner)
    }

    private func framed(_ token: String) -> Data {
        Data(
            "\u{1E}EDITH_CLAUDE_TOKEN_\(marker)_BEGIN\u{1F}\(token)\u{1E}EDITH_CLAUDE_TOKEN_\(marker)_END\u{1F}"
                .utf8)
    }

    private func expectMalformed(_ output: Data) async {
        let resolution = await makeResolver { _, _, _ in .output(output) }.resolve()
        guard case .malformed = resolution else {
            Issue.record("expected malformed output")
            return
        }
    }

    private func expect(
        _ expected: ExpectedResolution, from result: ClaudeShellProcessResult
    ) async {
        let resolution = await makeResolver { _, _, _ in result }.resolve()
        switch (expected, resolution) {
        case (.missing, .missing), (.timedOut, .timedOut), (.oversized, .oversized),
            (.failed, .failed):
            return
        default:
            Issue.record("unexpected resolution")
        }
    }
}

@MainActor
@Suite struct ClaudeCredentialSessionTests {
    @Test func keychainPrecedesTheCredentialsFile() throws {
        let keychain = try credentialData("keychain-token")
        let file = try credentialData("file-token")
        var requestedFile: URL?
        let credential = ClaudeCredentialStore.read(
            home: URL(fileURLWithPath: "/tmp/credential-home"),
            keychainData: { keychain },
            fileData: {
                requestedFile = $0
                return file
            })
        #expect(credential?.accessToken == "keychain-token")
        #expect(credential?.source == .keychain)
        #expect(requestedFile == nil)
    }

    @Test func malformedKeychainFallsBackToTheCredentialsFile() throws {
        let home = URL(fileURLWithPath: "/tmp/credential-home")
        let file = try credentialData("file-token")
        var requestedFile: URL?
        let credential = ClaudeCredentialStore.read(
            home: home,
            keychainData: { Data("invalid".utf8) },
            fileData: {
                requestedFile = $0
                return file
            })
        #expect(credential?.accessToken == "file-token")
        #expect(
            credential?.source == .file(home.appendingPathComponent(".claude/.credentials.json")))
        #expect(requestedFile == home.appendingPathComponent(".claude/.credentials.json"))
    }

    @Test func persistedCredentialsPrecedeTheShell() async throws {
        let persisted = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let shell = ClaudeShellCredentialQueue(tokens: ["shell-token"])
        let session = ClaudeCredentialSession(
            persistedReader: { persisted },
            shellReader: { shell.next() })
        let credential = await session.current()
        #expect(credential?.accessToken == "persisted-token")
        #expect(credential?.source == .keychain)
        #expect(shell.calls == 0)
    }

    @Test func shellCredentialIsResolvedOnceAndCachedOnlyInMemory() async {
        let shell = ClaudeShellCredentialQueue(tokens: ["shell-token", "unused-token"])
        let session = ClaudeCredentialSession(
            persistedReader: { nil },
            shellReader: { shell.next() })
        let first = await session.current()
        let second = await session.current()
        #expect(first?.accessToken == "shell-token")
        #expect(second?.accessToken == "shell-token")
        #expect(first?.source == .shell)
        #expect(shell.calls == 1)
    }

    @Test func reloadAfterUnauthorizedResolvesExactlyOnceAndRotates() async {
        let shell = ClaudeShellCredentialQueue(tokens: [
            "old-token", "rotated-token", "unused-token",
        ])
        let session = ClaudeCredentialSession(
            persistedReader: { nil },
            shellReader: { shell.next() })
        let rejected = await session.current()
        let rotated = await session.reload()
        let cached = await session.current()
        #expect(rejected?.accessToken == "old-token")
        #expect(rotated?.accessToken == "rotated-token")
        #expect(cached?.accessToken == "rotated-token")
        #expect(shell.calls == 2)
    }

    private func credentialData(_ accessToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": "refresh-token",
            ]
        ])
    }
}
