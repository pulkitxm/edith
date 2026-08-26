import EdithKit
import Foundation
import Testing

@testable import EdithHelper

private actor UsageReloadPublicationHarness {
    private var generation = UsageReloadGenerationState()
    private var value = ""

    func publishOlder(
        after release: AsyncStream<Void>, started: AsyncStream<Void>.Continuation
    ) async {
        let request = generation.begin()
        started.yield()
        for await _ in release { break }
        if generation.accepts(request) { value = "older" }
    }

    func publishNewer() {
        let request = generation.begin()
        if generation.accepts(request) { value = "newer" }
    }

    func publishedValue() -> String {
        value
    }
}

private final class MutableHistoryURL: @unchecked Sendable {
    private let lock = NSLock()
    private var current: URL

    init(_ url: URL) {
        current = url
    }

    func resolve() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func update(_ url: URL) {
        lock.lock()
        current = url
        lock.unlock()
    }
}

@Suite struct LimitsRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func refreshesEveryEnabledProviderRegardlessOfSelection() {
        #expect(UsageStore.enabledLimitProviders(claude: true, codex: true) == [.claude, .codex])
        #expect(UsageStore.enabledLimitProviders(claude: true, codex: false) == [.claude])
        #expect(UsageStore.enabledLimitProviders(claude: false, codex: true) == [.codex])
        #expect(UsageStore.enabledLimitProviders(claude: false, codex: false).isEmpty)
    }

    @Test func onlyTheCurrentLimitsRefreshCanPublish() {
        #expect(
            UsageStore.canPublishLimitsRefresh(
                generation: 4, currentGeneration: 4, terminating: false, cancelled: false))
        #expect(
            !UsageStore.canPublishLimitsRefresh(
                generation: 3, currentGeneration: 4, terminating: false, cancelled: false))
        #expect(
            !UsageStore.canPublishLimitsRefresh(
                generation: 4, currentGeneration: 4, terminating: true, cancelled: false))
        #expect(
            !UsageStore.canPublishLimitsRefresh(
                generation: 4, currentGeneration: 4, terminating: false, cancelled: true))
    }

    @Test func startsWhenNothingIsInFlight() {
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: nil, retryNotBefore: nil, now: now) == .start)
    }

    @Test func skipsWhileARefreshIsStillRunning() {
        let started = now.addingTimeInterval(-30)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: started, retryNotBefore: nil, now: now)
                == .skipInFlight)
        #expect(
            LimitsRefreshGate.decide(
                force: true, inFlightSince: started, retryNotBefore: nil, now: now)
                == .skipInFlight)
    }

    @Test func recoversWhenAnInFlightRefreshNeverFinished() {
        let wedged = now.addingTimeInterval(-LimitsRefreshGate.stallTimeout)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: wedged, retryNotBefore: nil, now: now)
                == .recoverStalled)
    }

    @Test func recoveryStillHonoursBackoffUnlessForced() {
        let wedged = now.addingTimeInterval(-3600)
        let gate = now.addingTimeInterval(600)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: wedged, retryNotBefore: gate, now: now)
                == .skipBackoff)
        #expect(
            LimitsRefreshGate.decide(
                force: true, inFlightSince: wedged, retryNotBefore: gate, now: now)
                == .recoverStalled)
    }

    @Test func backoffBlocksPollingUntilItExpires() {
        let gate = now.addingTimeInterval(600)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: nil, retryNotBefore: gate, now: now) == .skipBackoff)
        #expect(
            LimitsRefreshGate.decide(
                force: true, inFlightSince: nil, retryNotBefore: gate, now: now) == .start)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: nil, retryNotBefore: now.addingTimeInterval(-1),
                now: now) == .start)
    }

    @Test func backoffNeverParksThePollerForDays() {
        let week: TimeInterval = 7 * 24 * 3600
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: week, now: now)
                == now.addingTimeInterval(LimitsRefreshGate.maximumBackoff))
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: 5, now: now)
                == now.addingTimeInterval(LimitsRefreshGate.minimumBackoff))
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: nil, now: now)
                == now.addingTimeInterval(LimitsRefreshGate.maximumBackoff))
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: 300, now: now)
                == now.addingTimeInterval(300))
    }

    @Test func historyCompletionCannotStartPollingWhilePaused() {
        #expect(UsageStore.pollingAllowed(locked: false, sleeping: false))
        #expect(!UsageStore.pollingAllowed(locked: true, sleeping: false))
        #expect(!UsageStore.pollingAllowed(locked: false, sleeping: true))
        #expect(!UsageStore.pollingAllowed(locked: true, sleeping: true))
    }

    @MainActor
    @Test func credentialLookupFailuresStayActionableAndSecretSafe() {
        let missing = UsageStore.credentialLookupFailurePresentation(for: .missing)
        let rejected = UsageStore.credentialLookupFailurePresentation(for: .rejected)
        let malformed = UsageStore.credentialLookupFailurePresentation(for: .malformed)
        let oversized = UsageStore.credentialLookupFailurePresentation(for: .oversized)

        #expect(missing.message == "Claude Code token not found")
        #expect(!missing.schedulesQuickRetry)
        #expect(rejected.message.contains("re-login"))
        #expect(rejected.notifiesExpiredSession)
        #expect(malformed.message.contains("invalid"))
        #expect(oversized.message.contains("too large"))
        #expect(!malformed.schedulesQuickRetry)
        #expect(!oversized.schedulesQuickRetry)
        for presentation in [missing, rejected, malformed, oversized] {
            #expect(!presentation.message.contains("token-value"))
            #expect(!presentation.diagnostic.contains("token-value"))
        }
        for presentation in [malformed, oversized] {
            #expect(!presentation.message.lowercased().contains("shell"))
            #expect(!presentation.diagnostic.lowercased().contains("shell"))
        }
    }

    @MainActor
    @Test func transientCredentialLookupFailuresScheduleBoundedRetry() {
        let timedOut = UsageStore.credentialLookupFailurePresentation(for: .timedOut)
        let failed = UsageStore.credentialLookupFailurePresentation(for: .failed)

        #expect(timedOut.schedulesQuickRetry)
        #expect(failed.schedulesQuickRetry)
        #expect(!timedOut.notifiesExpiredSession)
        #expect(!failed.notifiesExpiredSession)
        #expect(!timedOut.message.lowercased().contains("shell"))
        #expect(!failed.message.lowercased().contains("shell"))
    }

    @Test func usageStatusMappingDistinguishesPermissionFailures() {
        #expect(UsageStore.fetchError(statusCode: 401) == .unauthorized)
        #expect(UsageStore.fetchError(statusCode: 403) == .permissionDenied)
        #expect(
            UsageStore.fetchError(statusCode: 429, retryAfter: 120)
                == .rateLimited(after: 120))
        #expect(UsageStore.fetchError(statusCode: 500) == .http(500))
        #expect(UsageStore.fetchError(statusCode: 200) == nil)
    }

    @Test func historyWritesWaitForSeedAndFlushOncePerProvider() {
        var gate = HistoryWriteGate()
        let firstClaude = gate.record(.claude)
        let codex = gate.record(.codex)
        let secondClaude = gate.record(.claude)
        let pending = gate.finish()
        let readyClaude = gate.record(.claude)
        let drained = gate.finish()
        #expect(!firstClaude)
        #expect(!codex)
        #expect(!secondClaude)
        #expect(pending == [.codex, .claude])
        #expect(readyClaude)
        #expect(drained.isEmpty)
    }

    @Test func delayedOlderReloadCannotReplaceANewerPublication() async {
        let harness = UsageReloadPublicationHarness()
        let release = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let older = Task {
            await harness.publishOlder(after: release.stream, started: started.continuation)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()

        await harness.publishNewer()
        release.continuation.yield()
        await older.value

        #expect(await harness.publishedValue() == "newer")
    }

    @Test func historyPersistenceRetainsFailuresAndRetriesWithinTheRequestedBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-history-persistence-\(UUID().uuidString)")
        let historyURL = root.appendingPathComponent("limits-history.jsonl")
        let target = root.appendingPathComponent("outside.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: historyURL, withDestinationURL: target)
        let worker = UsageHistoryPersistenceWorker(historyURL: historyURL)
        let entry = UsageHistoryPersistenceEntry(
            provider: .claude, session: LimitWindow(percent: 42, resetsAt: nil), week: nil,
            fable: nil)

        #expect(await worker.persist([entry]) == false)
        #expect(await worker.drain(maxAttempts: 2, retryNanoseconds: 0) == false)
        #expect(await worker.pendingCount() == 1)
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))

        try FileManager.default.removeItem(at: historyURL)
        #expect(await worker.drain(maxAttempts: 1, retryNanoseconds: 0))
        #expect(await worker.pendingCount() == 0)
        #expect(LimitsHistory.latest(url: historyURL)?.session?.percent == 42)
    }

    @Test func historyPersistenceResolvesTheRuntimePathForEveryWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-history-path-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first/limits-history.jsonl")
        let second = root.appendingPathComponent("second/limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MutableHistoryURL(first)
        let worker = UsageHistoryPersistenceWorker(historyURLResolver: { resolver.resolve() })
        let firstEntry = UsageHistoryPersistenceEntry(
            provider: .claude, session: LimitWindow(percent: 21, resetsAt: nil), week: nil,
            fable: nil)
        let secondEntry = UsageHistoryPersistenceEntry(
            provider: .claude, session: LimitWindow(percent: 84, resetsAt: nil), week: nil,
            fable: nil)

        #expect(await worker.persist([firstEntry]))
        resolver.update(second)
        #expect(await worker.persist([secondEntry]))

        #expect(LimitsHistory.latest(url: first)?.session?.percent == 21)
        #expect(LimitsHistory.latest(url: second)?.session?.percent == 84)
    }
}
