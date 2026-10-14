import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

private actor LimitsLoginProbe {
    private(set) var requests: [CLICommandRequest] = []
    private(set) var writes: [(URL, Data)] = []
    func request(_ value: CLICommandRequest) { requests.append(value) }
    func write(_ folder: URL, _ value: Data) { writes.append((folder, value)) }
}

private actor LinkedLoginAuthority {
    private var allowed = true
    func revoke() { allowed = false }
    func isCurrent() -> Bool { allowed }
}

@Suite struct ClaudeLimitsLoginTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func login(expiry: Date, token: String = "synthetic-access") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "preserved": "synthetic-metadata",
            "claudeAiOauth": [
                "accessToken": token, "refreshToken": "synthetic-refresh",
                "expiresAt": expiry.timeIntervalSince1970 * 1000, "scopes": ["user:profile"],
            ],
        ])
    }

    private func response(_ status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse
    {
        try #require(
            HTTPURLResponse(
                url: URL(string: "https://synthetic.invalid/token")!, statusCode: status,
                httpVersion: nil, headerFields: headers))
    }

    private func fixture() async throws -> (URL, ClaudeAccountStorage, ClaudeAccount, URL) {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let directory = root.appendingPathComponent("Accounts", isDirectory: true)
            let storage = ClaudeAccountStorage(directory: directory)
            let original = ClaudeAccount(
                name: "Synthetic launch", credential: "synthetic-exact-launch")
            try await storage.save(.init(accounts: [original], defaultID: original.id))
            let state = try await storage.connectLimitsLogin(
                account: original, startLogin: { _, _ in }, eraseScopedSecret: { _ in })
            let account = try #require(state.accounts.first)
            return (
                root, storage, account, try await storage.limitsLoginCredentials(account: account).0
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test func renewalPreservesMetadataRefreshCredentialsAndExactRequestContract() async throws {
        let source = try login(expiry: now.addingTimeInterval(-1))
        let reply = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-renewed", "refresh_token": "synthetic-rotated",
            "expires_in": 3600, "scope": "user:profile user:inference",
        ])
        let updated = try await ClaudeLimitsLogin.renew(source, now: now) { request in
            #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try #require(
                JSONSerialization.jsonObject(with: try #require(request.httpBody))
                    as? [String: String])
            #expect(body["refresh_token"] == "synthetic-refresh")
            #expect(body["grant_type"] == "refresh_token")
            #expect(body["scope"] == "user:profile")
            #expect(body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
            return (reply, try response(200))
        }
        let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let oauth = try #require(object["claudeAiOauth"] as? [String: Any])
        #expect(object["preserved"] as? String == "synthetic-metadata")
        #expect(oauth["refreshToken"] as? String == "synthetic-rotated")
        #expect(
            oauth["expiresAt"] as? Double == now.addingTimeInterval(3600).timeIntervalSince1970
                * 1000)
        #expect(ClaudeSavedLogin.token(data: updated, now: now) == "synthetic-renewed")
    }

    @Test func renewalRejectsRejectedStatusScopeInvalidTokensAndOversizedResponses() async throws {
        let source = try login(expiry: now.addingTimeInterval(-1))
        for status in [400, 401, 403, 429, 500] {
            await #expect(throws: ClaudeLimitsReader.Failure.self) {
                _ = try await ClaudeLimitsLogin.renew(source, now: now) { _ in
                    (Data(), try response(status, headers: ["Retry-After": "120"]))
                }
            }
        }
        for reply: [String: Any] in [
            ["access_token": "synthetic-token", "expires_in": 3600, "scope": "user:inference"],
            ["access_token": "bad\ntoken", "expires_in": 3600, "scope": "user:profile"],
            ["access_token": "synthetic-token", "expires_in": 0, "scope": "user:profile"],
        ] {
            let responseData = try JSONSerialization.data(withJSONObject: reply)
            await #expect(throws: ClaudeLimitsReader.Failure.self) {
                _ = try await ClaudeLimitsLogin.renew(source, now: now) { _ in
                    (responseData, try response(200))
                }
            }
        }
        await #expect(throws: ClaudeLimitsReader.Failure.self) {
            _ = try await ClaudeLimitsLogin.renew(source, now: now) { _ in
                (Data(repeating: 1, count: 65_537), try response(200))
            }
        }
    }

    @Test func nativeCredentialRequestsUseOnlyExactScopeAndKeepWriteDataOffArguments() async throws
    {
        let first = URL(fileURLWithPath: "/synthetic/accounts/first")
        let second = URL(fileURLWithPath: "/synthetic/accounts/second")
        #expect(ClaudeLimitsLogin.service(first) != ClaudeLimitsLogin.service(second))
        let data = try login(expiry: now.addingTimeInterval(3600))
        let probe = LimitsLoginProbe()
        let read = try await ClaudeLimitsLogin.nativeCredentials(
            folder: first, username: "synthetic-user",
            run: { request, _ in
                await probe.request(request)
                return .init(terminationStatus: 0, outputData: data)
            })
        #expect(read != nil)
        try await ClaudeLimitsLogin.saveNative(
            data, folder: first, username: "synthetic-user",
            run: { request, _ in
                await probe.request(request)
                return .init(terminationStatus: 0, output: "")
            })
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(
            requests.allSatisfy {
                $0.executableURL.path == "/usr/bin/security" && $0.environment.isEmpty
                    && $0.timeout == 3 && $0.discardsStandardError
            })
        #expect(requests[0].arguments.contains(ClaudeLimitsLogin.service(first)))
        #expect(!requests[0].arguments.contains("Claude Code-credentials"))
        #expect(requests[0].maximumOutputBytes == 65_537)
        #expect(requests[1].arguments == ["-i"])
        #expect(requests[1].maximumOutputBytes == 1024)
        let input = String(decoding: try #require(requests[1].standardInputData), as: UTF8.self)
        #expect(input.contains(ClaudeLimitsLogin.service(first)))
        #expect(!input.contains("synthetic-access"))
        #expect(input.contains(data.map { String(format: "%02x", $0) }.joined()))
    }

    @Test func nativeOnlyLoginWinsOverPrivateFileWithoutChangingLaunchCredential() async throws {
        let (root, storage, account, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await storage.load()
        let previous = try login(expiry: now.addingTimeInterval(-1), token: "synthetic-old-file")
        try await storage.saveLimitsLoginCredentials(
            account: account, expected: nil, data: previous)
        let native = try login(expiry: now.addingTimeInterval(3600), token: "synthetic-native")
        let token = try await ClaudeLimitsLogin.token(
            account: account, directory: storage.directory,
            services: .init(
                readNative: {
                    #expect($0 == folder); return native
                },
                writeNative: { _, _ in Issue.record("Valid native login was rewritten") },
                send: { _ in
                    Issue.record("Valid native login was renewed"); throw CancellationError()
                },
                now: { now }))
        #expect(token == "synthetic-native")
        #expect(try await storage.limitsLoginCredentials(account: account).1 == previous)
        #expect(try await storage.load() == original)
        #expect(account.credential == "synthetic-exact-launch")
    }

    @Test func expiredLinkedLoginRenewsBothOwnedStoresAndRejectsRevokedPublication() async throws {
        let (root, storage, account, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try login(expiry: now.addingTimeInterval(-1))
        try await storage.saveLimitsLoginCredentials(
            account: account, expected: nil, data: previous)
        let reply = try JSONSerialization.data(withJSONObject: [
            "access_token": "synthetic-renewed", "expires_in": 3600, "scope": "user:profile",
        ])
        let probe = LimitsLoginProbe()
        let services = ClaudeLimitsLogin.Services(
            readNative: { _ in nil }, writeNative: { await probe.write($0, $1) },
            send: { _ in (reply, try response(200)) }, now: { now })
        #expect(
            try await ClaudeLimitsLogin.token(
                account: account, directory: storage.directory, services: services)
                == "synthetic-renewed")
        let written = try #require(await probe.writes.first)
        #expect(written.0 == folder)
        #expect(try await storage.limitsLoginCredentials(account: account).1 == written.1)
        #expect(try await storage.load().accounts.first?.credential == account.credential)
        try await storage.saveLimitsLoginCredentials(
            account: account, expected: written.1, data: previous)
        var revoked = services
        revoked.writeNative = { _, _ in
            let foreign = ClaudeAccountStorage(directory: storage.directory)
            await #expect(throws: ClaudeAccountError.self) {
                _ = try await foreign.logout(id: account.id, eraseScopedSecret: { _ in })
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await ClaudeLimitsLogin.token(
                account: account, directory: storage.directory, services: revoked)
        }
        #expect(try await storage.load().accounts.first?.isLoggedOut == true)
    }

    @Test func linkedResolutionNeverFallsBackToLaunchTokenAndChecksFreshAccountAfterAwait()
        async throws
    {
        var account = ClaudeAccount(name: "Synthetic linked", credential: "synthetic-launch")
        account.limitsProfileID = UUID()
        let expected = account
        let directory = URL(fileURLWithPath: "/synthetic/accounts")
        #expect(throws: ClaudeLimitsReader.Failure.self) {
            try ClaudeLimitsReader.accountToken(account, directory: directory)
        }
        let token = try await ClaudeLimitsReader.resolveAccountToken(
            account, directory: directory, isCurrent: { _, _ in true },
            savedLogin: { _, _ in
                Issue.record("Linked login read browser seed"); return nil
            },
            remoteLogin: { _ in
                Issue.record("Linked login read remote credentials"); return nil
            },
            linkedLogin: { selected, scope in
                #expect(selected == expected && scope == directory)
                return "synthetic-linked"
            })
        #expect(token == "synthetic-linked")
        await #expect(throws: ClaudeLimitsReader.Failure.self) {
            _ = try await ClaudeLimitsReader.resolveAccountToken(
                account, directory: directory, isCurrent: { _, _ in true },
                linkedLogin: { _, _ in throw ClaudeLimitsReader.Failure.missingToken })
        }
        let authority = LinkedLoginAuthority()
        await #expect(throws: CancellationError.self) {
            _ = try await ClaudeLimitsReader.resolveAccountToken(
                expected, directory: directory, isCurrent: { _, _ in await authority.isCurrent() },
                linkedLogin: { _, _ in
                    await authority.revoke()
                    return "synthetic-stale-token"
                })
        }
    }
}
