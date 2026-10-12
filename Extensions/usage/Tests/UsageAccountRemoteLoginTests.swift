import EdithExtensionAccounts
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

private actor RemoteAccountProbe {
    private(set) var machines: [UUID] = []
    private(set) var calls = 0
    private(set) var active = 0
    func entered(_ machine: UUID) { machines.append(machine); calls += 1; active += 1 }
    func left() { active -= 1 }
}

private actor SavedAccountProbe {
    private(set) var current = true
    func revoke() { current = false }
}

@Suite struct UsageAccountRemoteLoginTests {
    private let environment = ["EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.tests.accounts"]
    private let directory = URL(fileURLWithPath: "/synthetic/accounts")

    private func account(machine: UUID = UUID()) -> ClaudeAccount {
        var value = ClaudeAccount(name: "Synthetic remote", authentication: .browserLogin)
        value.remoteMachineID = machine.uuidString
        return value
    }

    @Test func onlyTheExplicitAssociatedHostReadsItsAppOwnedUUIDProfile() async throws {
        let value = account()
        let selected = try #require(UUID(uuidString: value.remoteMachineID!))
        let other = UUID()
        let probe = RemoteAccountProbe()
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "synthetic-token", "scopes": ["user:profile"],
                "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            ]
        ])
        let peer = UsageMachinesPeer(
            active: { true },
            invoke: { command, payload in
                #expect(command == "machines.companion.run")
                let request = try #require(
                    JSONSerialization.jsonObject(with: payload) as? [String: Any])
                let machine = try #require(UUID(uuidString: request["machineID"] as? String ?? ""))
                await probe.entered(machine)
                let source = try #require(request["command"] as? String)
                #expect(source.contains(value.id.uuidString))
                #expect(source.contains("com.pulkit.edith.tests.accounts"))
                #expect(!source.contains(".claude/"))
                #expect(!source.contains("synthetic-token"))
                #expect(request["timeout"] as? Int == 5)
                await probe.left()
                return try JSONSerialization.data(withJSONObject: [
                    "output": String(decoding: data, as: UTF8.self)
                ])
            })
        let token = try await ClaudeAccountRemoteLogin.token(
            account: value, environment: environment, currentPeer: { peer })
        #expect(token == "synthetic-token")
        #expect(await probe.machines == [selected])
        #expect(!(await probe.machines).contains(other))
    }

    @Test func disabledMachinesLoggedOutAccountsAndStaleAccountsNeverInvokeARead() async throws {
        let value = account()
        await #expect(throws: ExtensionPeerError.self) {
            try await ClaudeAccountRemoteLogin.token(
                account: value, environment: environment, currentPeer: { nil })
        }
        let inactive = UsageMachinesPeer(
            active: { false },
            invoke: { _, _ in
                Issue.record("Disabled Machines read credentials"); return Data()
            })
        await #expect(throws: ExtensionPeerError.self) {
            try await ClaudeAccountRemoteLogin.token(
                account: value, environment: environment, currentPeer: { inactive })
        }
        var loggedOut = value
        loggedOut.isLoggedOut = true
        #expect(
            try await ClaudeAccountRemoteLogin.token(
                account: loggedOut, environment: environment,
                currentPeer: {
                    Issue.record("Logged-out account resolved Machines"); return inactive
                }) == nil)
        await #expect(throws: CancellationError.self) {
            try await ClaudeLimitsReader.resolveAccountToken(
                value, directory: directory, isCurrent: { _, _ in false },
                savedLogin: { _, _ in
                    Issue.record("Stale account read local login"); return nil
                },
                remoteLogin: { _ in
                    Issue.record("Stale account read remote login"); return nil
                })
        }
    }

    @Test func cancellationJoinsOwnedRemoteReadsAndSchedulesNoFurtherAccounts() async throws {
        let probe = RemoteAccountProbe()
        let collector = ClaudeAccountLimitsCollector()
        let configured = (0..<8).map { _ in account() }
        let peer = UsageMachinesPeer(
            active: { true },
            invoke: { _, payload in
                let request = try #require(
                    JSONSerialization.jsonObject(with: payload) as? [String: Any])
                let machine = try #require(UUID(uuidString: request["machineID"] as? String ?? ""))
                await probe.entered(machine)
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    await probe.left(); throw error
                }
                await probe.left()
                return Data()
            })
        let owner = Task {
            try await collector.refresh(accounts: configured, directory: directory) { value, _ in
                _ = try await ClaudeAccountRemoteLogin.token(
                    account: value, environment: environment, currentPeer: { peer })
                return .init(provider: .claude, session: nil, week: nil)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await probe.active != 3 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        owner.cancel()
        await #expect(throws: CancellationError.self) { try await owner.value }
        #expect(await probe.active == 0)
        #expect(await probe.calls == 3)
    }

    @Test func credentialEditsAndRemoteAssociationCannotPublishAStaleToken() async throws {
        let value = account()
        let reads = RemoteAccountProbe()
        await #expect(throws: CancellationError.self) {
            try await ClaudeLimitsReader.resolveAccountToken(
                value, directory: directory,
                isCurrent: { _, _ in
                    await reads.entered(UUID()); await reads.left()
                    return await reads.calls == 1
                }, savedLogin: { _, _ in "synthetic-token" },
                remoteLogin: { _ in
                    Issue.record("Valid scoped token read remotely"); return nil
                })
        }
        #expect(await reads.calls == 2)
    }

    @Test func remoteProfileCommandRejectsUnscopedApplicationIdentifiers() {
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountRemoteLogin.readCommand(
                accountID: UUID(), environment: ["EDITH_APPLICATION_IDENTIFIER": "../../other"])
        }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountRemoteLogin.readCommand(accountID: UUID(), environment: [:])
        }
    }

    @Test func revocationWhileHTTPRunsAbortsWithoutCachingItsSuccessfulQuotaResponse() async throws
    {
        let value = account()
        let saved = SavedAccountProbe()
        let collector = ClaudeAccountLimitsCollector()
        await #expect(throws: CancellationError.self) {
            try await collector.refresh(accounts: [value], directory: directory) {
                value, directory in
                try await ClaudeLimitsReader.fetchAccount(
                    value, directory: directory, isCurrent: { _, _ in await saved.current },
                    resolveToken: { "synthetic-token" },
                    send: { request in
                        await saved.revoke()
                        let data = Data("{\"five_hour\":{\"utilization\":23}}".utf8)
                        return (
                            data,
                            HTTPURLResponse(
                                url: request.url!, statusCode: 200,
                                httpVersion: nil, headerFields: nil)!
                        )
                    })
            }
        }
        let fresh = try await collector.refresh(accounts: [value], directory: directory) { _, _ in
            .init(provider: .claude, session: .init(percent: 42, resetsAt: nil), week: nil)
        }
        #expect(fresh.first?.limits.session?.percent == 42)
    }
}
