import Foundation
import Testing

@testable import EdithKit

@Suite struct BoundedKeychainAccessTests {
    @Test func stuckLookupTimesOutWithoutStartingMoreWorkers() async {
        let access = BoundedKeychainAccess<Int>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = await access.run(timeout: 0.05, fallback: -1) {
            release.wait()
            return 1
        }
        #expect(first == -1)
        for _ in 0..<20 {
            let next = await access.run(timeout: 0.05, fallback: -1) {
                Issue.record("a blocked lookup must not spawn another worker")
                return 2
            }
            #expect(next == -1)
        }
    }

    @Test func completedLookupCanBeRetriedAfterTimeout() async throws {
        let access = BoundedKeychainAccess<Int>()
        let release = DispatchSemaphore(value: 0)
        let first = await access.run(timeout: 0.02, fallback: -1) {
            release.wait()
            return 1
        }
        #expect(first == -1)
        release.signal()
        var recovered = -1
        for _ in 0..<100 {
            recovered = await access.run(timeout: 1, fallback: -1) { 2 }
            if recovered == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(recovered == 2)
    }

    @Test func previousDeadlineCannotCompleteANewerLookup() async {
        let access = BoundedKeychainAccess<Int>()
        let first = await access.run(timeout: 0.05, fallback: -1) { 1 }
        #expect(first == 1)
        let second = await access.run(timeout: 1, fallback: -1) {
            Thread.sleep(forTimeInterval: 0.1)
            return 2
        }
        #expect(second == 2)
    }

    @Test func credentialFileRemainsUsableAfterKeychainTimeout() async throws {
        let access = BoundedKeychainAccess<ClaudeCredentialDataLookup>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let keychain = await access.run(timeout: 0.02, fallback: .timedOut) {
            release.wait()
            return .missing
        }
        let document = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-token"}}"#.utf8)
        let home = URL(fileURLWithPath: "/tmp/synthetic-credential-home")
        let lookup = ClaudeCredentialStore.read(
            home: home, keychainData: keychain, fileData: { _ in .data(document) })
        guard case .credential(let credential) = lookup else {
            Issue.record("the credentials file must remain available")
            return
        }
        #expect(credential.accessToken == "synthetic-token")
        #expect(
            credential.source == .file(home.appendingPathComponent(".claude/.credentials.json")))
    }

    @Test func stuckKeychainDoesNotBlockOtherProvidersOrLaterRefreshes() async {
        let access = BoundedKeychainAccess<ClaudeCredentialDataLookup>()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = LimitsRefreshSession()
        for percentage in [25.0, 30.0] {
            let result = await LimitsCollector.collect(
                providers: [.claude, .codex], refreshSession: session,
                now: Date(), announce: { _ in }
            ) { provider in
                if provider == .claude {
                    _ = await access.run(timeout: 0.02, fallback: .timedOut) {
                        release.wait()
                        return .missing
                    }
                    return (
                        LimitsProviderSnapshot(
                            provider: provider, session: nil, week: nil, error: "Credential timeout"
                        ),
                        nil
                    )
                }
                return (
                    LimitsProviderSnapshot(
                        provider: provider, session: nil,
                        week: LimitWindow(percent: percentage, resetsAt: nil)), nil
                )
            }
            #expect(result.providers.last?.week?.percent == percentage)
        }
    }
}
