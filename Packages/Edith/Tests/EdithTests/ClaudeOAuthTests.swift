import Darwin
import EdithKit
import Foundation
import Testing

@testable import EdithHelper

private extension ClaudeCredentialLookup {
    var credential: ClaudeOAuthCredential? {
        guard case .credential(let credential) = self else { return nil }
        return credential
    }

    var failure: ClaudeCredentialLookupFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

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

private final class ClaudeSecurityCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CLICommandRequest?

    func record(_ request: CLICommandRequest) {
        lock.lock()
        stored = request
        lock.unlock()
    }

    var request: CLICommandRequest? {
        lock.lock()
        defer { lock.unlock() }
        return stored
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

    @Test func transientTokensStayMemoryOnly() async throws {
        let credential = try #require(
            ClaudeOAuthCredential.transient(accessToken: "shell-access"))
        #expect(credential.source == .shell)
        #expect(credential.refreshToken == nil)
        #expect(credential.expiresAt == nil)
        await #expect(throws: ClaudeCredentialStoreError.self) {
            try await ClaudeCredentialStore.persist(Data("secret".utf8), source: .shell)
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

    @Test func cancellationStopsTheLiveShellAndItsDescendant() async throws {
        let fixture = try cancellationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let resolver = ClaudeShellCredentialResolver(
            shell: fixture.executable,
            home: fixture.directory,
            username: "tester",
            timeout: 10,
            maximumOutputBytes: 4_096,
            marker: marker)
        let task = Task { await resolver.resolve() }
        let identifiers = try await processIdentifiers(fixture)

        task.cancel()
        let resolution = await task.value

        guard case .cancelled = resolution else {
            Issue.record("expected cancellation to remain distinct from failure")
            return
        }
        try await expectGone(identifiers)
    }

    private enum ExpectedResolution {
        case missing
        case timedOut
        case oversized
        case failed
    }

    private struct CancellationFixture {
        let directory: URL
        let executable: URL
        let parent: URL
        let child: URL
    }

    private func cancellationFixture() throws -> CancellationFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-shell-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fixture-shell")
        let parent = directory.appendingPathComponent("parent.pid")
        let child = directory.appendingPathComponent("child.pid")
        let script = """
            #!/bin/sh
            printf '%s\n' "$$" > "\(parent.path)"
            trap '' TERM
            /bin/sleep 30 &
            printf '%s\n' "$!" > "\(child.path)"
            wait
            """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return CancellationFixture(
            directory: directory, executable: executable, parent: parent, child: child)
    }

    private func processIdentifiers(_ fixture: CancellationFixture) async throws -> [Int32] {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if let parent = identifier(at: fixture.parent),
                let child = identifier(at: fixture.child)
            {
                return [parent, child]
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while true
    }

    private func identifier(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
        else { return nil }
        return Int32(text)
    }

    private func expectGone(_ identifiers: [Int32]) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while identifiers.contains(where: isPresent) {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                Issue.record("resolver process remained after cancellation")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func isPresent(_ identifier: Int32) -> Bool {
        errno = 0
        return kill(identifier, 0) == 0 || errno != ESRCH
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
        let credential = (await session.current()).credential
        #expect(credential?.accessToken == "persisted-token")
        #expect(credential?.source == .keychain)
        #expect(shell.calls == 0)
    }

    @Test func shellCredentialIsResolvedOnceAndCachedOnlyInMemory() async {
        let shell = ClaudeShellCredentialQueue(tokens: ["shell-token", "unused-token"])
        let session = ClaudeCredentialSession(
            persistedReader: { nil },
            shellReader: { shell.next() })
        let first = (await session.current()).credential
        let second = (await session.current()).credential
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
        let rejected = (await session.current()).credential
        let rotated = (await session.reload()).credential
        let cached = (await session.current()).credential
        #expect(rejected?.accessToken == "old-token")
        #expect(rotated?.accessToken == "rotated-token")
        #expect(cached?.accessToken == "rotated-token")
        #expect(shell.calls == 2)
    }

    @Test func rejectedPersistedCredentialFallsBackToTheShellOnce() async throws {
        let persisted = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let shell = ClaudeShellCredentialQueue(tokens: ["rotated-shell-token"])
        let session = ClaudeCredentialSession(
            persistedReader: { persisted },
            shellReader: { shell.next() })

        let initial = (await session.current()).credential
        let recovered =
            (await session.reload(rejectingAccessToken: "persisted-token")).credential
        let cached = (await session.current()).credential

        #expect(initial?.accessToken == "persisted-token")
        #expect(recovered?.accessToken == "rotated-shell-token")
        #expect(recovered?.source == .shell)
        #expect(cached?.accessToken == "rotated-shell-token")
        #expect(shell.calls == 1)
    }

    @Test func rotatedPersistedCredentialStillPrecedesTheShellOnRetry() async throws {
        let original = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let rotated = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("rotated-persisted-token"), source: .keychain))
        var reads = 0
        let shell = ClaudeShellCredentialQueue(tokens: ["shell-token"])
        let session = ClaudeCredentialSession(
            persistedReader: {
                reads += 1
                return reads == 1 ? original : rotated
            },
            shellReader: { shell.next() })

        let initial = (await session.current()).credential
        let recovered =
            (await session.reload(rejectingAccessToken: "persisted-token")).credential

        #expect(initial?.accessToken == "persisted-token")
        #expect(recovered?.accessToken == "rotated-persisted-token")
        #expect(recovered?.source == .keychain)
        #expect(shell.calls == 0)
    }

    @Test func rejectedCredentialStaysRejectedAcrossLoads() async throws {
        let persisted = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let session = ClaudeCredentialSession(
            persistedReader: { persisted },
            shellReader: { .missing })

        _ = await session.current()
        let rejected = await session.reload(rejectingAccessToken: "persisted-token")
        let nextLoad = await session.current()

        #expect(rejected.failure == .rejected)
        #expect(nextLoad.failure == .rejected)
    }

    @Test func rejectedPersistedTokenIsAlsoRejectedFromTheShell() async throws {
        let persisted = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let shell = ClaudeShellCredentialQueue(tokens: ["persisted-token", "persisted-token"])
        let session = ClaudeCredentialSession(
            persistedReader: { persisted },
            shellReader: { shell.next() })

        _ = await session.current()
        let rejected = await session.reload(rejectingAccessToken: "persisted-token")
        let repeated = await session.current()

        #expect(rejected.failure == .rejected)
        #expect(repeated.failure == .rejected)
        #expect(shell.calls == 2)
    }

    @Test func rotatedShellTokenClearsTheRejection() async throws {
        let persisted = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let shell = ClaudeShellCredentialQueue(tokens: [
            "persisted-token", "rotated-shell-token",
        ])
        let session = ClaudeCredentialSession(
            persistedReader: { persisted },
            shellReader: { shell.next() })

        _ = await session.current()
        let rejected = await session.reload(rejectingAccessToken: "persisted-token")
        let rotated = (await session.current()).credential
        let cached = (await session.current()).credential

        #expect(rejected.failure == .rejected)
        #expect(rotated?.accessToken == "rotated-shell-token")
        #expect(cached?.accessToken == "rotated-shell-token")
        #expect(shell.calls == 2)
    }

    @Test func explicitStoreClearsTheRejection() async throws {
        let persisted = try #require(
            ClaudeOAuthCredential.decode(
                credentialData("persisted-token"), source: .keychain))
        let session = ClaudeCredentialSession(
            persistedReader: { persisted },
            shellReader: { .missing })

        _ = await session.current()
        _ = await session.reload(rejectingAccessToken: "persisted-token")
        session.store(persisted)
        let restored = (await session.current()).credential

        #expect(restored?.accessToken == "persisted-token")
    }

    @Test func shellCancellationRemainsDistinctFromLookupFailure() async {
        let session = ClaudeCredentialSession(
            persistedReader: { nil },
            shellReader: { .cancelled })

        let lookup = await session.current()

        guard case .cancelled = lookup else {
            Issue.record("expected cancellation to remain distinct from lookup failure")
            return
        }
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

@Suite struct ClaudeCredentialStoreProcessTests {
    @Test func keychainReadUsesBoundedSecretSafeExecution() async throws {
        let capture = ClaudeSecurityCommandCapture()
        let credential = try credentialData("keychain-token")

        let result = await ClaudeCredentialStore.keychainData(
            securityExecutable: URL(fileURLWithPath: "/usr/bin/security"), timeout: 0.5,
            maximumOutputBytes: 4_096,
            runCommand: { request in
                capture.record(request)
                return CLICommandResult(terminationStatus: 0, outputData: credential)
            })

        let request = try #require(capture.request)
        #expect(result == credential)
        #expect(
            request.arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        #expect(request.timeout == 0.5)
        #expect(request.maximumOutputBytes == 4_096)
        #expect(request.standardInputData == nil)
        #expect(request.discardsStandardError)
        #expect(request.terminatesProcessGroup)
        #expect(!request.arguments.joined().contains("keychain-token"))
        #expect(!request.environment.values.joined().contains("keychain-token"))
    }

    @Test func keychainUpdateUsesBoundedStdinWithoutExposingTheCredential() async throws {
        let capture = ClaudeSecurityCommandCapture()
        let credential = try credentialData("private-token")

        try await ClaudeCredentialStore.persist(
            credential, source: .keychain,
            securityExecutable: URL(fileURLWithPath: "/usr/bin/security"), timeout: 0.5,
            maximumOutputBytes: 512,
            runCommand: { request in
                capture.record(request)
                return CLICommandResult(terminationStatus: 0, output: "")
            })

        let request = try #require(capture.request)
        #expect(request.timeout == 0.5)
        #expect(request.maximumOutputBytes == 512)
        #expect(request.discardsStandardError)
        #expect(request.terminatesProcessGroup)
        #expect(!request.arguments.joined().contains("private-token"))
        #expect(!request.environment.values.joined().contains("private-token"))
        #expect(
            request.standardInputData == credential + Data("\n".utf8) + credential + Data("\n".utf8)
        )
    }

    @Test func oversizedSecurityOutputIsStoppedAndRejected() async throws {
        let fixture = try shim("while :; do printf '01234567890123456789012345678901'; done")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let started = ProcessInfo.processInfo.systemUptime

        let result = await ClaudeCredentialStore.keychainData(
            securityExecutable: fixture.executable, timeout: 5, maximumOutputBytes: 1_024)

        #expect(result == nil)
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

    @Test func stalledSecurityUpdateReturnsOnlyAGenericError() async throws {
        let fixture = try shim("trap '' TERM\n/bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let credential = try credentialData("private-token")
        let started = ProcessInfo.processInfo.systemUptime

        do {
            try await ClaudeCredentialStore.persist(
                credential, source: .keychain, securityExecutable: fixture.executable,
                timeout: 0.1, maximumOutputBytes: 1_024)
            Issue.record("expected keychain failure")
        } catch let error as ClaudeCredentialStoreError {
            #expect(error == .keychainUpdateFailed)
            #expect(error.localizedDescription == "Keychain update failed")
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

    private struct ShimFixture {
        let directory: URL
        let executable: URL
    }

    private func shim(_ body: String) throws -> ShimFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-security-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("security")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return ShimFixture(directory: directory, executable: executable)
    }

    private func credentialData(_ accessToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": accessToken, "refreshToken": "refresh-token"]
        ])
    }
}
