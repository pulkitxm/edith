import EdithCore
import Foundation
import Testing

@testable import EdithKit

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

@Suite struct ClaudeAccountRemoteLoginTests {
    private let directory = URL(fileURLWithPath: "/synthetic/accounts")

    private func account(machine: UUID = UUID()) -> ClaudeAccount {
        var value = ClaudeAccount(name: "Synthetic remote", authentication: .browserLogin)
        value.remoteMachineID = machine.uuidString
        return value
    }

    private func machine(_ id: UUID) -> Machine {
        Machine(id: id, name: "Synthetic machine", host: "fixture.invalid")
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
        let machines = [machine(other), machine(selected)]
        let token = try await ClaudeAccountRemoteLogin.token(
            account: value, machines: { machines },
            run: { target, source in
                await probe.entered(target.id)
                #expect(source.contains(value.id.uuidString))
                #expect(source.contains(AppBuildIdentity.application))
                #expect(!source.contains(".claude/"))
                #expect(!source.contains("synthetic-token"))
                await probe.left()
                return SSHExecResult(status: 0, stdout: data, stderr: Data())
            })
        #expect(token == "synthetic-token")
        #expect(await probe.machines == [selected])
    }

    @Test func missingMachinesLoggedOutAccountsAndStaleAccountsNeverInvokeARead() async throws {
        let value = account()
        await #expect(throws: ClaudeLimitsReader.Failure.self) {
            try await ClaudeAccountRemoteLogin.token(
                account: value, machines: { [] },
                run: { _, _ in
                    Issue.record("Missing machine ran a read")
                    return SSHExecResult(status: 1, stdout: Data(), stderr: Data())
                })
        }
        var loggedOut = value
        loggedOut.isLoggedOut = true
        #expect(
            try await ClaudeAccountRemoteLogin.token(
                account: loggedOut,
                machines: {
                    Issue.record("Logged-out account resolved machines"); return []
                },
                run: { _, _ in SSHExecResult(status: 1, stdout: Data(), stderr: Data()) })
                == nil)
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

    @Test func failedRemoteReadsReportAMissingLogin() async throws {
        let value = account()
        let selected = try #require(UUID(uuidString: value.remoteMachineID!))
        await #expect(throws: ClaudeLimitsReader.Failure.missingToken) {
            try await ClaudeAccountRemoteLogin.token(
                account: value, machines: { [machine(selected)] },
                run: { _, _ in SSHExecResult(status: 1, stdout: Data(), stderr: Data()) })
        }
    }

    @Test func cancellationJoinsOwnedRemoteReadsAndSchedulesNoFurtherAccounts() async throws {
        let probe = RemoteAccountProbe()
        let collector = ClaudeAccountLimitsCollector()
        let configured = (0..<8).map { _ in account() }
        let machines = configured.map { machine(UUID(uuidString: $0.remoteMachineID!)!) }
        let owner = Task {
            try await collector.refresh(accounts: configured, directory: directory) { value, _ in
                _ = try await ClaudeAccountRemoteLogin.token(
                    account: value, machines: { machines },
                    run: { target, _ in
                        await probe.entered(target.id)
                        do { try await Task.sleep(for: .seconds(60)) } catch {
                            await probe.left(); throw error
                        }
                        await probe.left()
                        return SSHExecResult(status: 1, stdout: Data(), stderr: Data())
                    })
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

    @Test func remoteProfileCommandRejectsUnscopedApplicationIdentifiers() throws {
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountRemoteLogin.readCommand(accountID: UUID(), namespace: "../../other")
        }
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeAccountRemoteLogin.readCommand(accountID: UUID(), namespace: "")
        }
        let id = UUID()
        let command = try ClaudeAccountRemoteLogin.readCommand(
            accountID: id, namespace: "com.pulkit.edith")
        #expect(command.hasPrefix("python3 -c "))
        #expect(
            command.hasSuffix(
                " '.local' 'share' 'edith' 'com.pulkit.edith' 'accounts' '\(id.uuidString)'"))
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
