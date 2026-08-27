import Combine
import Foundation
import Testing

@testable import EdithKit
@testable import EdithHelper

private actor LidAwakeRestorationLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LidAwakeOutcomeLatch {
    private var continuation: CheckedContinuation<LidAwakeOutcome, Never>?
    private var outcome: LidAwakeOutcome?

    func wait() async -> LidAwakeOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ outcome: LidAwakeOutcome) {
        self.outcome = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private final class LidAwakeCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class LidAwakeThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var ranOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value = Thread.isMainThread
        lock.unlock()
    }
}

private actor LidAwakeApplySequence {
    private var outcomes: [LidAwakeOutcome]
    private var calls: [Bool] = []
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(_ outcomes: [LidAwakeOutcome]) {
        self.outcomes = outcomes
    }

    func apply(_ active: Bool) -> LidAwakeOutcome {
        calls.append(active)
        if let waiter, calls.count >= waiter.count {
            self.waiter = nil
            waiter.continuation.resume()
        }
        return outcomes.isEmpty ? .failed("unexpected mutation") : outcomes.removeFirst()
    }

    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }

    var appliedStates: [Bool] { calls }
}

private func lidAwakeProcessesExit(_ processIDs: [pid_t], timeout: TimeInterval = 1) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        let running = processIDs.contains { processID in
            kill(processID, 0) == 0 || errno == EPERM
        }
        if !running { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return false
}

private func lidAwakeProcessIDs(at url: URL) throws -> [pid_t] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: " ")
        .compactMap { pid_t($0) }
}

@Suite struct LidAwakeTests {
    @Test func runtimeContextDecodesOneFiniteAbsoluteDeadline() throws {
        let requestID = UUID().uuidString
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = now.addingTimeInterval(30)
        var payload: [AnyHashable: Any] = [
            LidAwakeIPC.actionKey: LidAwakeIPC.Action.on.rawValue,
            LidAwakeIPC.sessionKey: LidAwakeSession.thirtyMinutes.rawValue,
            LidAwakeIPC.requestIDKey: requestID,
            LidAwakeIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]

        let runtimeRequest = try #require(LidAwakeRuntimeRequest(runtimePayload: payload))
        payload[LidAwakeIPC.deadlineKey] = now.addingTimeInterval(-1).timeIntervalSince1970

        #expect(runtimeRequest.request == .on(.thirtyMinutes))
        #expect(runtimeRequest.context.requestID == requestID)
        #expect(runtimeRequest.context.deadline == deadline)
        #expect(runtimeRequest.context.isLive(at: now))
        #expect(runtimeRequest.context.remainingTimeInterval(at: now) == 30)
        #expect(!runtimeRequest.context.isLive(at: deadline))
        #expect(runtimeRequest.context.remainingTimeInterval(at: deadline) == 0)
    }

    @Test func runtimeContextRejectsMalformedCorrelationAndDeadlines() {
        let requestID = UUID().uuidString
        let validDeadline = Date().addingTimeInterval(30).timeIntervalSince1970

        #expect(LidAwakeRuntimeRequestContext(runtimePayload: [:]) == nil)
        #expect(
            LidAwakeRuntimeRequestContext(
                runtimePayload: [
                    LidAwakeIPC.requestIDKey: "not-a-uuid",
                    LidAwakeIPC.deadlineKey: validDeadline,
                ]) == nil)
        for deadline in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(
                LidAwakeRuntimeRequestContext(
                    runtimePayload: [
                        LidAwakeIPC.requestIDKey: requestID,
                        LidAwakeIPC.deadlineKey: deadline,
                    ]) == nil)
        }
    }

    @Test func automaticStopPendingStatePersistsAndClearsExactly() throws {
        let suite = "test.lidawake.pending.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(!LidAwakeState.automaticStopPending(defaults))
        #expect(!LidAwakeState.restorationNeeded(defaults))
        LidAwakeState.setAutomaticStopPending(true, defaults)
        #expect(LidAwakeState.automaticStopPending(defaults))
        #expect(LidAwakeState.restorationNeeded(defaults))
        #expect(defaults.object(forKey: LidAwakeState.automaticStopPendingKey) as? Bool == true)

        LidAwakeState.setAutomaticStopPending(false, defaults)
        #expect(!LidAwakeState.automaticStopPending(defaults))
        #expect(defaults.object(forKey: LidAwakeState.automaticStopPendingKey) == nil)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        #expect(LidAwakeState.restorationNeeded(defaults))
    }

    @MainActor @Test func powerMutationsRunInSubmissionOrder() async {
        let sequencer = LidAwakeMutationSequencer()
        var events: [String] = []
        let first = sequencer.enqueue {
            events.append("first-start")
            try? await Task.sleep(for: .milliseconds(20))
            events.append("first-end")
        }
        let second = sequencer.enqueue {
            events.append("second")
        }

        await second.value

        #expect(events == ["first-start", "first-end", "second"])
        await first.value
    }

    @MainActor @Test func drainingWaitsForEverySubmittedPowerMutation() async {
        let sequencer = LidAwakeMutationSequencer()
        var events: [String] = []
        sequencer.enqueue {
            events.append("start")
            try? await Task.sleep(for: .milliseconds(20))
            events.append("finish")
        }

        await sequencer.drain()

        #expect(events == ["start", "finish"])
    }

    @MainActor @Test func restorationGatePublishesOneCompletedOutcome() async {
        let gate = LidAwakeRestorationGate()
        let latch = LidAwakeRestorationLatch()
        var completions = 0
        let restoration = Task { @MainActor in
            await latch.wait()
            return LidAwakeOutcome.failed("restore refused")
        }
        var outcome: LidAwakeOutcome?

        gate.begin(restoration) {
            outcome = $0
            completions += 1
        }

        #expect(gate.isRestoring)
        await latch.release()
        #expect(await gate.waitForOutcome() == .failed("restore refused"))

        #expect(!gate.isRestoring)
        #expect(completions == 1)
        #expect(outcome == .failed("restore refused"))
    }

    @MainActor @Test func pastSavedDeadlineStopsWithoutRenewingTheSession() async throws {
        let suite = "test.lidawake.deadline.expired.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let expiredDeadline = Date().addingTimeInterval(-60)
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setSession(.oneHour, defaults)
        LidAwakeState.setSessionDeadline(expiredDeadline, defaults)
        let sequence = LidAwakeApplySequence([.applied])
        var deadlineObservedDuringStop: Date?

        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { true },
            applySystemState: { active in
                deadlineObservedDuringStop = LidAwakeState.sessionDeadline(defaults)
                return await sequence.apply(active)
            }, startServices: false, automaticStopRetries: 0)

        await sequence.waitForCalls(1)
        for _ in 0..<100 {
            if !engine.snapshot().applying { break }
            await Task.yield()
        }

        #expect(await sequence.appliedStates == [false])
        #expect(
            abs(
                try #require(deadlineObservedDuringStop).timeIntervalSince(expiredDeadline))
                < 0.001)
        #expect(!engine.snapshot().active)
        #expect(LidAwakeState.sessionDeadline(defaults) == nil)
        #expect(!LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func pendingAutomaticStopRetriesOnRestart() async throws {
        let suite = "test.lidawake.pending.restart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setAutomaticStopPending(true, defaults)
        let sequence = LidAwakeApplySequence([.applied])

        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { true },
            applySystemState: { await sequence.apply($0) }, startServices: false,
            automaticStopRetries: 0)

        await sequence.waitForCalls(1)
        for _ in 0..<100 {
            if !engine.snapshot().applying { break }
            await Task.yield()
        }

        #expect(await sequence.appliedStates == [false])
        #expect(!engine.snapshot().active)
        #expect(!LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func finalAutomaticStopFailureRetainsPendingState() async throws {
        let suite = "test.lidawake.pending.failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        let sequence = LidAwakeApplySequence([
            .failed("temporary failure"), .failed("restore refused"),
        ])
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { true },
            applySystemState: { await sequence.apply($0) }, startServices: false,
            automaticStopRetries: 1)

        engine.requestAutomaticStop()
        await sequence.waitForCalls(2)
        for _ in 0..<100 {
            if !engine.snapshot().applying { break }
            await Task.yield()
        }

        #expect(await sequence.appliedStates == [false, false])
        #expect(engine.snapshot().active)
        #expect(engine.snapshot().lastError == "restore refused")
        #expect(LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func failedActivationRemainsRestorableUntilTerminationCompletes() async throws
    {
        let suite = "test.lidawake.activation.failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        let activation = LidAwakeOutcomeLatch()
        let restorationStarted = LidAwakeRestorationLatch()
        let releaseRestoration = LidAwakeRestorationLatch()
        var appliedStates: [Bool] = []
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { active in
                appliedStates.append(active)
                if active { return .failed("reply lost") }
                await restorationStarted.release()
                await releaseRestoration.wait()
                return .applied
            }, startServices: false)

        engine.start(session: .oneHour) { outcome in
            Task { await activation.resolve(outcome) }
        }

        #expect(await activation.wait() == .failed("reply lost"))
        #expect(engine.snapshot().active)
        #expect(defaults.bool(forKey: LidAwakeState.activeKey))

        let termination = Task { @MainActor in
            await engine.shutdownForTermination()
        }
        await restorationStarted.wait()
        #expect(LidAwakeState.automaticStopPending(defaults))
        termination.cancel()
        #expect(LidAwakeState.automaticStopPending(defaults))
        await releaseRestoration.release()
        await termination.value

        #expect(appliedStates == [true, false])
        #expect(!defaults.bool(forKey: LidAwakeState.activeKey))
        #expect(!LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func inactiveUninstallSkipsThePrivilegedMutationAfterConfirmedRead()
        async throws
    {
        let suite = "test.lidawake.uninstall.inactive.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        var appliedStates: [Bool] = []
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: {
                appliedStates.append($0)
                return .failed("helper unavailable")
            }, startServices: false,
            systemStateReader: { false })

        let restoration = try #require(engine.uninstall())
        let outcome = await restoration.value

        #expect(outcome == .applied)
        #expect(appliedStates.isEmpty)
        #expect(!LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func explicitOnSupersedesPendingAutomaticStop() async throws {
        let suite = "test.lidawake.pending.on.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        LidAwakeState.setAutomaticStopPending(true, defaults)
        let sequence = LidAwakeApplySequence([.applied])
        let completion = LidAwakeOutcomeLatch()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { await sequence.apply($0) }, startServices: false)

        engine.start(session: .thirtyMinutes) { outcome in
            Task { await completion.resolve(outcome) }
        }

        #expect(await completion.wait() == .applied)
        #expect(await sequence.appliedStates == [true])
        #expect(engine.snapshot().active)
        #expect(!LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func confirmedOffClearsPendingStateAndDeadline() async throws {
        let suite = "test.lidawake.pending.off.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setSession(.oneHour, defaults)
        LidAwakeState.setSessionDeadline(Date().addingTimeInterval(600), defaults)
        let sequence = LidAwakeApplySequence([.applied])
        let completion = LidAwakeOutcomeLatch()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { true },
            applySystemState: { await sequence.apply($0) }, startServices: false)
        LidAwakeState.setAutomaticStopPending(true, defaults)

        engine.stop { outcome in
            Task { await completion.resolve(outcome) }
        }

        #expect(await completion.wait() == .applied)
        #expect(await sequence.appliedStates == [false])
        #expect(!engine.snapshot().active)
        #expect(!LidAwakeState.automaticStopPending(defaults))
        #expect(LidAwakeState.sessionDeadline(defaults) == nil)
    }

    @MainActor @Test func submittedMutationSupersedesBlockedSystemRead() async throws {
        let suite = "test.lidawake.read.mutation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        let readerStarted = LidAwakeRestorationLatch()
        let releaseReader = LidAwakeRestorationLatch()
        let sequence = LidAwakeApplySequence([.applied])
        let completion = LidAwakeOutcomeLatch()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { await sequence.apply($0) }, startServices: false,
            systemStateReader: {
                await readerStarted.release()
                await releaseReader.wait()
                return false
            })

        engine.refreshFromSystem()
        await readerStarted.wait()
        engine.start(session: .indefinite) { outcome in
            Task { await completion.resolve(outcome) }
        }
        #expect(await completion.wait() == .applied)
        await releaseReader.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(await sequence.appliedStates == [true])
        #expect(engine.snapshot().active)
        #expect(engine.snapshot().requestedActive)
        #expect(defaults.bool(forKey: LidAwakeState.activeKey))
    }

    @MainActor @Test func orphanRecoveryClearsConfirmedAndStaleState() async throws {
        let suite = "test.lidawake.orphan.restore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setAutomaticStopPending(true, defaults)
        LidAwakeState.setSessionDeadline(Date().addingTimeInterval(60), defaults)
        var appliedStates: [Bool] = []

        let outcome = await LidAwakeEngine.restoreOrphanedState(
            defaults: defaults, readSystemState: { true },
            applySystemState: {
                appliedStates.append($0)
                return .applied
            }, announceChange: {})

        #expect(outcome == .applied)
        #expect(appliedStates == [false])
        #expect(!defaults.bool(forKey: LidAwakeState.activeKey))
        #expect(!LidAwakeState.automaticStopPending(defaults))
        #expect(LidAwakeState.sessionDeadline(defaults) == nil)

        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setAutomaticStopPending(true, defaults)
        let stale = await LidAwakeEngine.restoreOrphanedState(
            defaults: defaults, readSystemState: { false },
            applySystemState: { _ in .failed("must not run") }, announceChange: {})

        #expect(stale == .applied)
        #expect(!defaults.bool(forKey: LidAwakeState.activeKey))
        #expect(!LidAwakeState.automaticStopPending(defaults))
    }

    @MainActor @Test func failedOrphanRecoveryPreservesEveryRecoveryMarker() async throws {
        let suite = "test.lidawake.orphan.failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setAutomaticStopPending(true, defaults)
        let deadline = Date().addingTimeInterval(-30)
        LidAwakeState.setSessionDeadline(deadline, defaults)

        let outcome = await LidAwakeEngine.restoreOrphanedState(
            defaults: defaults, readSystemState: { true },
            applySystemState: { _ in .failed("restore refused") }, announceChange: {})

        #expect(outcome == .failed("restore refused"))
        #expect(defaults.bool(forKey: LidAwakeState.activeKey))
        #expect(LidAwakeState.automaticStopPending(defaults))
        #expect(
            abs(
                try #require(LidAwakeState.sessionDeadline(defaults)).timeIntervalSince(deadline))
                < 0.001)
    }

    @MainActor @Test func newestSessionSelectionWinsApplyingActivation() async throws {
        let suite = "test.lidawake.session.race.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.enabledKey)
        LidAwakeState.setSession(.indefinite, defaults)
        let mutation = LidAwakeRestorationLatch()
        let completion = LidAwakeOutcomeLatch()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { _ in
                await mutation.wait()
                return .applied
            }, startServices: false)

        engine.start(session: .oneHour) { outcome in
            Task { await completion.resolve(outcome) }
        }
        LidAwakeState.setSession(.thirtyMinutes, defaults)
        engine.syncSettings()
        await mutation.release()

        #expect(await completion.wait() == .applied)
        #expect(engine.snapshot().session == .thirtyMinutes)
        #expect(LidAwakeState.session(defaults) == .thirtyMinutes)
    }

    @Test func commandTogglesTheLidCloseSleepPathway() {
        #expect(LidAwakeCommand.arguments(active: true) == ["-a", "disablesleep", "1"])
        #expect(LidAwakeCommand.arguments(active: false) == ["-a", "disablesleep", "0"])
        #expect(LidAwakeCommand.shellCommand(active: true) == "/usr/bin/pmset -a disablesleep 1")
    }

    @Test func unavailableHelperErrorsGiveTheCorrectRecovery() {
        let approval = LidAwakePrivilegedClientError.helperUnavailable(.awaitingApproval)
        #expect(
            approval.errorDescription?.contains("System Settings > General > Login Items") == true)
        let missing = LidAwakePrivilegedClientError.helperUnavailable(.notFound)
        #expect(missing.errorDescription?.contains("Reinstall Edith") == true)
        let registration = LidAwakePrivilegedClientError.helperUnavailable(.notRegistered)
        #expect(registration.errorDescription?.contains("Reopen Edith") == true)
        #expect(
            LidAwakePrivilegedClientError.timedOut.errorDescription?.contains("did not answer")
                == true)
    }

    @Test func privilegedRequestsDoNotRetryWhileApprovalIsPending() {
        let error = LidAwakePrivilegedClient.requestError(for: .awaitingApproval)
        #expect(error?.errorDescription?.contains("Approve Edith") == true)
        #expect(LidAwakePrivilegedClient.requestError(for: .enabled) == nil)
    }

    @Test func privilegedReplyTimesOutAndCancelsTheConnection() async {
        let reply = LidAwakePrivilegedReply()
        let probe = LidAwakeCancellationProbe()

        await #expect(throws: LidAwakePrivilegedClientError.self) {
            try await reply.wait(
                timeout: .milliseconds(20), cancel: { probe.record() }, send: { _ in })
        }
        #expect(probe.count == 1)
    }

    @Test func privilegedReplyCancellationFinishesImmediately() async {
        let reply = LidAwakePrivilegedReply()
        let probe = LidAwakeCancellationProbe()
        let task = Task {
            try await reply.wait(
                timeout: .seconds(10), cancel: { probe.record() }, send: { _ in })
        }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(probe.count == 1)
    }

    @Test func privilegedCommandKillsATermIgnoringProcessAtTheDeadline() throws {
        let started = Date()

        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05,
            terminationGrace: 0.05, pollInterval: 0.005)

        #expect(result.timedOut)
        #expect(!result.cancelled)
        #expect(result.terminationStatus != 0)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func privilegedCommandKillsTheIsolatedProcessGroupAtTheDeadline() throws {
        let processIDsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-awake-processes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDsURL) }
        let script = """
            trap '' TERM
            (trap '' TERM; while :; do sleep 1; done) &
            printf '%s %s' "$$" "$!" > "$1"
            while :; do sleep 1; done
            """

        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "lid-awake", processIDsURL.path], timeout: 0.05,
            terminationGrace: 0.05, pollInterval: 0.005)
        let processIDs = try lidAwakeProcessIDs(at: processIDsURL)

        #expect(result.timedOut)
        #expect(!result.cancelled)
        #expect(processIDs.count == 2)
        #expect(lidAwakeProcessesExit(processIDs))
    }

    @Test func privilegedCommandCancellationKillsTheIsolatedProcessGroup() throws {
        let processIDsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lid-awake-cancelled-processes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIDsURL) }
        let script = """
            trap '' TERM
            (trap '' TERM; while :; do sleep 1; done) &
            printf '%s %s' "$$" "$!" > "$1"
            while :; do sleep 1; done
            """

        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "lid-awake", processIDsURL.path], timeout: 5,
            terminationGrace: 0.05, pollInterval: 0.005,
            cancelled: { FileManager.default.fileExists(atPath: processIDsURL.path) })
        let processIDs = try lidAwakeProcessIDs(at: processIDsURL)

        #expect(!result.timedOut)
        #expect(result.cancelled)
        #expect(processIDs.count == 2)
        #expect(lidAwakeProcessesExit(processIDs))
    }

    @Test func privilegedCommandCapturesFailureWithoutTimingOut() throws {
        let result = try LidAwakeCommandProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf refused >&2; exit 7"], timeout: 1)

        #expect(!result.timedOut)
        #expect(!result.cancelled)
        #expect(result.terminationStatus == 7)
        #expect(result.standardError == "refused")
    }

    @Test func systemStateReadIsBoundedWhenTheProcessStalls() async {
        let started = Date()

        await #expect(throws: LidAwakeSystemStateReadError.self) {
            try await LidAwakeSystemStateReader.read(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.05)
        }

        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func systemStateReadRunsTheProcessOffTheMainThread() async throws {
        let probe = LidAwakeThreadProbe()
        let active = try await LidAwakeSystemStateReader.read(
            executableURL: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["-g"], timeout: 1,
            runner: { _, _, _, _ in
                probe.record()
                return LidAwakeCommandProcessResult(
                    terminationStatus: 0,
                    standardOutput: "System-wide power settings:\n SleepDisabled 1\n",
                    standardError: "", timedOut: false, cancelled: false)
            })

        #expect(active)
        #expect(probe.ranOnMainThread == false)
    }

    @Test func systemStateReadRejectsMissingSleepDisabledState() async {
        await #expect(throws: LidAwakeSystemStateReadError.malformedOutput) {
            try await LidAwakeSystemStateReader.read(
                executableURL: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["-g"],
                timeout: 1,
                runner: { _, _, _, _ in
                    LidAwakeCommandProcessResult(
                        terminationStatus: 0,
                        standardOutput: "Currently in use:\n standby 1\n", standardError: "",
                        timedOut: false, cancelled: false)
                })
        }
    }

    @Test func daemonIsPackagedInsideItsCallingApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Resources/com.pulkit.edith.lidawake.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any])
        #expect(
            plist["BundleProgram"] as? String
                == "Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake")
        let associated = plist["AssociatedBundleIdentifiers"] as? [String]
        #expect(
            associated?.contains(LidAwakePrivilegedService.clientBundleIdentifier) == true)
        let build = try String(
            contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        #expect(
            build.contains(
                "PRIVILEGED_HELPER=\"$HELPER/Contents/Library/PrivilegedHelperTools/com.pulkit.edith.lidawake\""
            ))
        #expect(
            build.contains(
                "LAUNCH_DAEMONS=\"$HELPER/Contents/Library/LaunchDaemons\""))
        let package = try String(
            contentsOf: root.appendingPathComponent("Packages/Edith/Package.swift"),
            encoding: .utf8)
        #expect(package.contains("\"__info_plist\""))
        let helperInfoURL = root.appendingPathComponent(
            "Packages/Edith/Sources/EdithLidAwakeHelper/Info.plist")
        let helperInfoData = try Data(contentsOf: helperInfoURL)
        let helperInfo = try #require(
            PropertyListSerialization.propertyList(from: helperInfoData, format: nil)
                as? [String: Any])
        #expect(
            helperInfo["CFBundleIdentifier"] as? String
                == LidAwakePrivilegedService.bundleIdentifier)
    }

    @Test func powerSettingsReportSleepDisabled() {
        let on = """
            System-wide power settings:
             SleepDisabled		1
            Currently in use:
             standby              1
            """
        let off = """
            System-wide power settings:
             SleepDisabled		0
            Currently in use:
             standby              1
            """
        #expect(LidAwakeCommand.sleepDisabled(inPowerSettings: on))
        #expect(!LidAwakeCommand.sleepDisabled(inPowerSettings: off))
        #expect(!LidAwakeCommand.sleepDisabled(inPowerSettings: "Currently in use:\n standby 1"))
        #expect(!LidAwakeCommand.sleepDisabled(inPowerSettings: ""))
    }

    @Test func installedAndActiveAreSeparateState() {
        #expect(LidAwakeState.enabledKey != LidAwakeState.activeKey)
        let defaults = UserDefaults(suiteName: "test.lidawake")!
        defaults.removePersistentDomain(forName: "test.lidawake")
        defer { defaults.removePersistentDomain(forName: "test.lidawake") }

        defaults.set(true, forKey: LidAwakeState.enabledKey)
        #expect(LidAwakeState.isEnabled(defaults))
        #expect(!LidAwakeState.isActive(defaults))

        LidAwakeState.setActive(true, defaults)
        #expect(LidAwakeState.isActive(defaults))

        LidAwakeState.setActive(false, defaults)
        #expect(!LidAwakeState.isActive(defaults))
        #expect(LidAwakeState.isEnabled(defaults), "closing the lid again must keep it installed")
    }

    @Test func inactiveWhenTheExtensionIsOff() {
        let defaults = UserDefaults(suiteName: "test.lidawake.off")!
        defaults.removePersistentDomain(forName: "test.lidawake.off")
        defer { defaults.removePersistentDomain(forName: "test.lidawake.off") }

        defaults.set(true, forKey: LidAwakeState.activeKey)
        #expect(!LidAwakeState.isActive(defaults))
    }

    @Test func sleepIsRestoredOnQuitUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "test.lidawake.quit")!
        defaults.removePersistentDomain(forName: "test.lidawake.quit")
        defer { defaults.removePersistentDomain(forName: "test.lidawake.quit") }

        #expect(LidAwakeState.restoresOnQuit(defaults))
        defaults.set(false, forKey: LidAwakeState.restoreOnQuitKey)
        #expect(!LidAwakeState.restoresOnQuit(defaults))
    }

    @Test func batteryPolicySuspendsBelowThresholdAndResumesOnAC() {
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: false, percent: 9, onAC: false, threshold: 10)
                == .suspend)
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: true, percent: 14, onAC: true, threshold: 10)
                == .none)
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: true, percent: 15, onAC: true, threshold: 10)
                == .resume)
        #expect(
            LidAwakeBatteryPolicy.decide(
                intent: true, suspended: true, percent: 100, onAC: true, threshold: 98)
                == .resume)
    }

    @Test func batteryThresholdIsBoundedAcrossStoredAndConfigurationReads() throws {
        let suite = "test.lidawake.battery.range.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(140, forKey: LidAwakeState.batteryThresholdKey)

        #expect(LidAwakeState.batteryThreshold(defaults) == 100)

        let executor = ConfigurationExecutor(
            shared: defaults, standard: defaults, announceChange: {})
        #expect(throws: ConfigurationError.self) {
            try executor.set(.int(-1), forKey: LidAwakeState.batteryThresholdKey)
        }
        #expect(throws: ConfigurationError.self) {
            try executor.set(.int(101), forKey: LidAwakeState.batteryThresholdKey)
        }
        try executor.set(.int(100), forKey: LidAwakeState.batteryThresholdKey)
        #expect(defaults.integer(forKey: LidAwakeState.batteryThresholdKey) == 100)
    }

    @Test func settingsBackupRejectsMalformedBatteryThresholds() {
        #expect(settingsBackupLidAwakeBatteryThreshold(0) == 0)
        #expect(settingsBackupLidAwakeBatteryThreshold(100) == 100)
        #expect(settingsBackupLidAwakeBatteryThreshold(-1) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(101) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(20.5) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(true) == nil)
        #expect(settingsBackupLidAwakeBatteryThreshold(Double.greatestFiniteMagnitude) == nil)
    }

    @Test func batteryOverrideLastsUntilAC() {
        #expect(LidAwakeBatteryPolicy.shouldKeepOverride(true, onAC: false))
        #expect(!LidAwakeBatteryPolicy.shouldKeepOverride(true, onAC: true))
        #expect(!LidAwakeBatteryPolicy.shouldKeepOverride(false, onAC: false))
    }

    @Test func lidSessionEndsAfterCloseAndReopen() {
        var tracker = LidAwakeLidSessionTracker()
        tracker.start(lidClosed: false)
        #expect(tracker.isActive)
        let remainedOpen = tracker.handle(lidClosed: false)
        #expect(!remainedOpen)
        let startedSession = tracker.handle(lidClosed: true)
        #expect(!startedSession)
        let endedSession = tracker.handle(lidClosed: false)
        #expect(endedSession)
        #expect(!tracker.isActive)
    }

    @Test func lidSessionStartedWithClosedLidWaitsForReopen() {
        var tracker = LidAwakeLidSessionTracker()
        tracker.start(lidClosed: true)
        let remainedClosed = tracker.handle(lidClosed: true)
        #expect(!remainedClosed)
        let endedSession = tracker.handle(lidClosed: false)
        #expect(endedSession)
    }
}
