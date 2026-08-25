import AppKit
import EdithKit

@MainActor
final class LidAwakeEngine: ObservableObject, FeatureModule {
    @Published private(set) var active = false
    @Published private(set) var applying = false
    @Published private(set) var lastError: String?
    @Published private(set) var session = LidAwakeSession.indefinite
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var batterySuspended = false

    private let privilegedClient = LidAwakePrivilegedClient()
    private let batteryMonitor = LidAwakeBatteryMonitor()
    private let lidMonitor = LidAwakeLidMonitor()
    private let displayWakeKeeper = LidAwakeDisplayWakeKeeper()
    private let autoOffTimer = LidAwakeAutoOffTimer()
    private var lidSession = LidAwakeLidSessionTracker()
    private var intent = false
    private var batteryOverride = false
    private var lastBattery: LidAwakeBatterySnapshot?
    private var terminateObserver: NSObjectProtocol?
    private var stopped = false
    private var refreshGeneration = 0
    private var initialRefreshPending = true

    init() {
        session = LidAwakeState.session()
        let savedDeadline = LidAwakeState.sessionDeadline()
        privilegedClient.register()
        active = LidAwakeState.isActive()
        intent = active
        if active {
            displayWakeKeeper.prevent()
            configureSession(session, deadline: savedDeadline)
        }
        batteryMonitor.onChange = { [weak self] snapshot in
            Task { @MainActor in self?.handleBattery(snapshot) }
        }
        lidMonitor.onChange = { [weak self] closed in
            Task { @MainActor in self?.handleLid(closed) }
        }
        autoOffTimer.onExpire = { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        autoOffTimer.onTick = { [weak self] in
            Task { @MainActor in self?.updateRemaining() }
        }
        batteryMonitor.start()
        lidMonitor.start()
        publishState()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopEngine(force: false, waitForRestore: true)
            }
        }
        refreshFromSystem()
    }

    func shutdown() {
        stopEngine(force: false)
    }

    func uninstall() {
        stopEngine(force: true)
    }

    func toggle() {
        if intent { stop() } else { start(session: session) }
    }

    func setActive(_ wanted: Bool) {
        if wanted { start(session: session) } else { stop() }
    }

    func start(
        session: LidAwakeSession, completion: ((LidAwakeOutcome) -> Void)? = nil
    ) {
        guard !stopped else {
            completion?(.failed("Lid Awake is not available."))
            return
        }
        guard !applying else {
            completion?(.failed("Lid Awake is already changing state."))
            return
        }
        let shouldOverride =
            lastBattery.map {
                !$0.onAC && $0.percent < batteryThreshold
            } ?? false
        if active, !batterySuspended {
            configureSession(session, deadline: nil)
            publishState()
            completion?(.applied)
            return
        }
        applySystemState(
            true,
            intentAfter: true,
            suspendedAfter: false,
            overrideAfter: shouldOverride,
            sessionAfter: session,
            configureSessionAfter: true,
            completion: completion)
    }

    func stop(completion: ((LidAwakeOutcome) -> Void)? = nil) {
        guard !stopped else {
            completion?(.failed("Lid Awake is not available."))
            return
        }
        guard !applying else {
            completion?(.failed("Lid Awake is already changing state."))
            return
        }
        guard active || intent else {
            completion?(.applied)
            return
        }
        applySystemState(
            false,
            intentAfter: false,
            suspendedAfter: false,
            overrideAfter: false,
            sessionAfter: session,
            configureSessionAfter: false,
            completion: completion)
    }

    func refreshFromSystem() {
        guard !applying, !stopped else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        Task { [weak self] in
            let system = await Self.readSystemState()
            guard let self, !self.stopped, !self.applying,
                generation == self.refreshGeneration
            else { return }
            self.applySystemSnapshot(system)
        }
    }

    private func applySystemSnapshot(_ system: Bool) {
        let initial = initialRefreshPending
        initialRefreshPending = false
        if batterySuspended {
            active = false
        } else if system != active {
            active = system
            intent = system
            if !system {
                displayWakeKeeper.allow()
                autoOffTimer.cancel()
                lidSession.cancel()
            } else if initial {
                displayWakeKeeper.prevent()
                configureSession(session, deadline: LidAwakeState.sessionDeadline())
            }
            publishState()
        }
        updateRemaining()
    }

    func syncSettings() {
        guard !stopped else { return }
        if batterySuspended, batteryThreshold == 0, intent, !applying {
            applySystemState(
                true,
                intentAfter: true,
                suspendedAfter: false,
                overrideAfter: false,
                sessionAfter: session,
                configureSessionAfter: false)
            return
        }
        if let lastBattery { handleBattery(lastBattery) }
        updateRemaining()
    }

    func statusPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "extensionEnabled": true,
            "active": active,
            "requestedActive": intent,
            "applying": applying,
            "batterySuspended": batterySuspended,
            "session": session.rawValue,
            "batteryThreshold": batteryThreshold,
            "restoreOnQuit": LidAwakeState.restoresOnQuit(),
            "helperStatus": privilegedClient.state.rawValue,
            "appRunning": true,
        ]
        if let remaining { payload["remainingSeconds"] = remaining }
        if let lastError = lastError ?? privilegedClient.registrationError {
            payload["lastError"] = lastError
        }
        return payload
    }

    func resultPayload(_ outcome: LidAwakeOutcome) -> [String: Any] {
        var payload = statusPayload()
        switch outcome {
        case .applied:
            payload[LidAwakeIPC.okKey] = true
        case .failed(let message):
            payload[LidAwakeIPC.okKey] = false
            payload[LidAwakeIPC.errorKey] = message
        }
        return payload
    }

    private var batteryThreshold: Int {
        SharedDefaults.store.integer(forKey: LidAwakeState.batteryThresholdKey)
    }

    private func handleBattery(_ snapshot: LidAwakeBatterySnapshot) {
        lastBattery = snapshot
        batteryOverride = LidAwakeBatteryPolicy.shouldKeepOverride(
            batteryOverride, onAC: snapshot.onAC)
        guard intent, !applying else { return }
        let action = LidAwakeBatteryPolicy.decide(
            intent: intent,
            suspended: batterySuspended,
            overridden: batteryOverride,
            percent: snapshot.percent,
            onAC: snapshot.onAC,
            threshold: batteryThreshold)
        switch action {
        case .suspend:
            applySystemState(
                false,
                intentAfter: true,
                suspendedAfter: true,
                overrideAfter: false,
                sessionAfter: session,
                configureSessionAfter: false)
        case .resume:
            applySystemState(
                true,
                intentAfter: true,
                suspendedAfter: false,
                overrideAfter: false,
                sessionAfter: session,
                configureSessionAfter: false)
        case .none:
            break
        }
    }

    private func handleLid(_ closed: Bool) {
        guard intent, session == .untilLidReopens, lidSession.isActive else { return }
        if lidSession.handle(lidClosed: closed) { stop() }
    }

    private func applySystemState(
        _ systemActive: Bool,
        intentAfter: Bool,
        suspendedAfter: Bool,
        overrideAfter: Bool,
        sessionAfter: LidAwakeSession,
        configureSessionAfter: Bool,
        completion: ((LidAwakeOutcome) -> Void)? = nil
    ) {
        guard !applying else { return }
        applying = true
        lastError = nil
        refreshGeneration += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.apply(systemActive: systemActive)
            self.finish(
                outcome,
                systemActive: systemActive,
                intentAfter: intentAfter,
                suspendedAfter: suspendedAfter,
                overrideAfter: overrideAfter,
                sessionAfter: sessionAfter,
                configureSessionAfter: configureSessionAfter,
                completion: completion)
        }
    }

    private func apply(systemActive: Bool) async -> LidAwakeOutcome {
        do {
            try await privilegedClient.setSleepDisabled(systemActive)
            return .applied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finish(
        _ outcome: LidAwakeOutcome,
        systemActive: Bool,
        intentAfter: Bool,
        suspendedAfter: Bool,
        overrideAfter: Bool,
        sessionAfter: LidAwakeSession,
        configureSessionAfter: Bool,
        completion: ((LidAwakeOutcome) -> Void)?
    ) {
        applying = false
        switch outcome {
        case .applied:
            active = systemActive
            intent = intentAfter
            batterySuspended = suspendedAfter
            batteryOverride = overrideAfter
            session = sessionAfter
            if systemActive { displayWakeKeeper.prevent() } else { displayWakeKeeper.allow() }
            if !intentAfter {
                autoOffTimer.cancel()
                lidSession.cancel()
                remaining = nil
                LidAwakeState.setSessionDeadline(nil)
            } else if configureSessionAfter {
                configureSession(sessionAfter, deadline: nil)
            } else {
                updateRemaining()
            }
            lastError = nil
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            publishState()
        case .failed(let message):
            lastError = message
        }
        completion?(outcome)
    }

    private func configureSession(_ session: LidAwakeSession, deadline: Date?) {
        self.session = session
        LidAwakeState.setSession(session)
        autoOffTimer.cancel()
        lidSession.cancel()
        switch session {
        case .indefinite:
            LidAwakeState.setSessionDeadline(nil)
        case .fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours:
            let minutes = session.minutes ?? 0
            let target =
                deadline.flatMap { $0 > Date() ? $0 : nil }
                ?? Date().addingTimeInterval(TimeInterval(minutes) * 60)
            autoOffTimer.start(deadline: target)
            LidAwakeState.setSessionDeadline(target)
        case .untilLidReopens:
            LidAwakeState.setSessionDeadline(nil)
            lidSession.start(lidClosed: lidMonitor.isClosed)
        }
        updateRemaining()
    }

    private func updateRemaining() {
        remaining = autoOffTimer.remaining
        if let deadline = autoOffTimer.deadline {
            LidAwakeState.setSessionDeadline(deadline)
        }
    }

    private func stopEngine(force: Bool, waitForRestore: Bool = false) {
        guard !stopped else { return }
        stopped = true
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        batteryMonitor.stop()
        lidMonitor.stop()
        displayWakeKeeper.allow()
        autoOffTimer.cancel()
        lidSession.cancel()
        let shouldRestore = active || batterySuspended || intent
        if shouldRestore && (force || LidAwakeState.restoresOnQuit()) {
            if waitForRestore {
                restoreBeforeTermination()
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let outcome = await self.apply(systemActive: false)
                    if case .applied = outcome { self.markRestored() }
                }
            }
        } else {
            markRestored()
        }
    }

    private func markRestored() {
        active = false
        intent = false
        batterySuspended = false
        LidAwakeState.setActive(false)
        IPC.post(IPC.Name.lidAwakeChanged)
    }

    private final class TerminationRestoreState: @unchecked Sendable {
        var finished = false
    }

    private func restoreBeforeTermination() {
        let state = TerminationRestoreState()
        Task { @MainActor [weak self] in
            defer { state.finished = true }
            guard let self else { return }
            let outcome = await self.apply(systemActive: false)
            if case .applied = outcome { self.markRestored() }
        }
        let deadline = Date().addingTimeInterval(1.5)
        while !state.finished, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func publishState() {
        LidAwakeState.setActive(active)
        LidAwakeState.setSession(session)
        IPC.post(IPC.Name.lidAwakeChanged)
    }

    private nonisolated static func readSystemState() async -> Bool {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: LidAwakeCommand.toolPath),
            arguments: ["-g"],
            environment: [:],
            timeout: 10,
            maximumOutputBytes: 1 << 20,
            discardsStandardError: true)
        guard let result = try? await CLICommandRunner.run(request, onLine: { _ in }) else {
            return false
        }
        return LidAwakeCommand.sleepDisabled(inPowerSettings: result.output)
    }
}
