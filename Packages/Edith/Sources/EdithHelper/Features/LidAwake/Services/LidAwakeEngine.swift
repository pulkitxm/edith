import AppKit
import EdithKit

@MainActor
final class LidAwakeMutationSequencer {
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let prior = tail
        let task = Task { @MainActor in
            await prior?.value
            await operation()
        }
        tail = task
        return task
    }

    func drain() async {
        await tail?.value
    }

    func enqueueResult<Result: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async -> Result
    ) -> Task<Result, Never> {
        let prior = tail
        let result = Task { @MainActor in
            await prior?.value
            return await operation()
        }
        tail = Task { @MainActor in
            _ = await result.value
        }
        return result
    }
}

@MainActor
final class LidAwakeRestorationGate {
    private var completionTask: Task<LidAwakeOutcome, Never>?
    private var completionGeneration: UInt = 0

    var isRestoring: Bool { completionTask != nil }

    func begin(
        _ restoration: Task<LidAwakeOutcome, Never>,
        completion: @escaping @MainActor @Sendable (LidAwakeOutcome) -> Void
    ) {
        guard completionTask == nil else { return }
        completionTask?.cancel()
        completionGeneration &+= 1
        let generation = completionGeneration
        completionTask = Task { @MainActor [weak self] in
            let outcome = await restoration.value
            guard !Task.isCancelled else { return outcome }
            guard let self, generation == self.completionGeneration else { return outcome }
            completionTask = nil
            completion(outcome)
            return outcome
        }
    }

    func wait() async {
        _ = await completionTask?.value
    }

    func waitForOutcome() async -> LidAwakeOutcome? {
        await completionTask?.value
    }
}

enum LidAwakeSafetyFollowUp: Equatable {
    case none
    case automaticStop
    case battery
}

struct LidAwakeSafetyReconciler {
    private(set) var batteryRevision: UInt = 0
    private var automaticStopPending = false

    mutating func recordBattery() {
        batteryRevision &+= 1
    }

    mutating func requestAutomaticStop(applying: Bool) -> Bool {
        if applying {
            automaticStopPending = true
            return false
        }
        return true
    }

    mutating func clearAutomaticStop() {
        automaticStopPending = false
    }

    mutating func followUp(
        stopped: Bool, mutationBatteryRevision: UInt, hasBattery: Bool
    ) -> LidAwakeSafetyFollowUp {
        if stopped {
            automaticStopPending = false
            return .none
        }
        if automaticStopPending {
            automaticStopPending = false
            return .automaticStop
        }
        if hasBattery, batteryRevision != mutationBatteryRevision {
            return .battery
        }
        return .none
    }
}

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
    private let mutationSequencer = LidAwakeMutationSequencer()
    private let defaults: UserDefaults
    private let applyOverride: (@MainActor @Sendable (Bool) async -> LidAwakeOutcome)?
    private let systemStateReader: (@Sendable () async throws -> Bool)?
    private let announceChange: @MainActor @Sendable () -> Void
    private let automaticStopRetries: Int
    private var lidSession = LidAwakeLidSessionTracker()
    private var safetyReconciler = LidAwakeSafetyReconciler()
    private var intent = false
    private var batteryOverride = false
    private var lastBattery: LidAwakeBatterySnapshot?
    private var sessionRevision: UInt = 0
    private var systemReadGeneration: UInt = 0
    private var systemReadTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private var stopped = false

    convenience init() {
        self.init(initialError: nil)
    }

    convenience init(initialError: String?) {
        self.init(
            defaults: SharedDefaults.store,
            readSystemState: {
                SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)
            },
            applySystemState: nil, startServices: true,
            systemStateReader: { try await LidAwakeSystemStateReader.read() },
            initialError: initialError,
            automaticStopRetries: 1)
    }

    init(
        defaults: UserDefaults, readSystemState: () -> Bool,
        applySystemState: (@MainActor @Sendable (Bool) async -> LidAwakeOutcome)?,
        startServices: Bool,
        systemStateReader: (@Sendable () async throws -> Bool)? = nil,
        initialError: String? = nil, automaticStopRetries: Int = 1,
        announceChange: @escaping @MainActor @Sendable () -> Void = {
            IPC.post(IPC.Name.lidAwakeChanged)
        }
    ) {
        self.defaults = defaults
        applyOverride = applySystemState
        self.systemStateReader = systemStateReader
        self.announceChange = announceChange
        self.automaticStopRetries = max(0, automaticStopRetries)
        session = LidAwakeState.session(defaults)
        lastError = initialError
        let savedDeadline = LidAwakeState.sessionDeadline(defaults)
        let automaticStopPending = LidAwakeState.automaticStopPending(defaults)
        if startServices { privilegedClient.register() }
        active = readSystemState()
        intent = active
        if active {
            displayWakeKeeper.prevent()
            if automaticStopPending {
                remaining = 0
            } else {
                configureSession(session, deadline: savedDeadline)
            }
        }
        batteryMonitor.onChange = { [weak self] snapshot in
            Task { @MainActor in self?.handleBattery(snapshot) }
        }
        lidMonitor.onChange = { [weak self] closed in
            Task { @MainActor in self?.handleLid(closed) }
        }
        autoOffTimer.onExpire = { [weak self] in
            Task { @MainActor in self?.requestAutomaticStop() }
        }
        autoOffTimer.onTick = { [weak self] in
            Task { @MainActor in self?.updateRemaining() }
        }
        if active, automaticStopPending { requestAutomaticStop() }
        if startServices {
            batteryMonitor.start()
            lidMonitor.start()
            refreshFromSystem()
        }
        publishState()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
    }

    func shutdown() {
        _ = stopEngine(force: false)
    }

    func shutdownForTermination() async {
        _ = stopEngine(force: false)
        await mutationSequencer.drain()
    }

    func uninstall() -> Task<LidAwakeOutcome, Never>? {
        stopEngine(force: true)
    }

    func execute(
        _ request: LidAwakeRequest, completion: ((LidAwakeOutcome) -> Void)? = nil
    ) {
        switch request {
        case .on(let session):
            start(session: session, completion: completion)
        case .off:
            stop(completion: completion)
        case .enableExtension, .disableExtension:
            completion?(.failed("The Lid Awake lifecycle request needs the service coordinator."))
        case .status:
            completion?(.applied)
        case .setBatteryThreshold, .setRestoreOnQuit:
            completion?(.failed("The Lid Awake request is not a runtime action."))
        }
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
        LidAwakeState.setAutomaticStopPending(false, defaults)
        safetyReconciler.clearAutomaticStop()
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
        stop(automaticRetriesRemaining: 0, completion: completion)
    }

    private func stop(
        automaticRetriesRemaining: Int,
        completion: ((LidAwakeOutcome) -> Void)? = nil
    ) {
        guard !stopped else {
            completion?(.failed("Lid Awake is not available."))
            return
        }
        guard !applying else {
            completion?(.failed("Lid Awake is already changing state."))
            return
        }
        guard active || intent || LidAwakeState.automaticStopPending(defaults) else {
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
            automaticRetriesRemaining: automaticRetriesRemaining,
            completion: completion)
    }

    func refreshFromSystem() {
        guard !applying, !stopped, let systemStateReader else { return }
        systemReadGeneration &+= 1
        let generation = systemReadGeneration
        systemReadTask?.cancel()
        let task = Task { @MainActor [weak self] in
            do {
                let system = try await systemStateReader()
                guard !Task.isCancelled else { return }
                guard let self, generation == self.systemReadGeneration, !self.applying,
                    !self.stopped
                else { return }
                self.reconcileSystemState(system)
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.systemReadGeneration, !self.stopped else {
                    return
                }
                self.lastError = error.localizedDescription
                self.announceChange()
            }
        }
        systemReadTask = task
    }

    private func reconcileSystemState(_ system: Bool) {
        if !system {
            LidAwakeState.setAutomaticStopPending(false, defaults)
            LidAwakeState.setSessionDeadline(nil, defaults)
            safetyReconciler.clearAutomaticStop()
        }
        if batterySuspended {
            active = false
        } else if system != active {
            active = system
            intent = system
            if !system {
                displayWakeKeeper.allow()
                autoOffTimer.cancel()
                lidSession.cancel()
            } else {
                displayWakeKeeper.prevent()
                if LidAwakeState.automaticStopPending(defaults) {
                    remaining = 0
                    requestAutomaticStop()
                } else {
                    configureSession(session, deadline: LidAwakeState.sessionDeadline(defaults))
                }
            }
            publishState()
        }
        updateRemaining()
    }

    func syncSettings() {
        guard !stopped else { return }
        let selectedSession = LidAwakeState.session(defaults)
        if selectedSession != session {
            sessionRevision &+= 1
            session = selectedSession
            if intent, !applying {
                configureSession(selectedSession, deadline: nil)
                publishState()
            }
        }
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

    func snapshot() -> LidAwakeSnapshot {
        LidAwakeSnapshot(
            extensionEnabled: true, active: active, requestedActive: intent,
            applying: applying, batterySuspended: batterySuspended, session: session,
            remainingSeconds: remaining, batteryThreshold: batteryThreshold,
            restoreOnQuit: LidAwakeState.restoresOnQuit(defaults),
            helperStatus: privilegedClient.state.rawValue, appRunning: true,
            lastError: lastError ?? privilegedClient.registrationError)
    }

    func resultPayload(
        _ outcome: LidAwakeOutcome, requestID: String? = nil
    ) -> [String: Any] {
        snapshot().resultPayload(outcome, requestID: requestID)
    }

    private var batteryThreshold: Int {
        LidAwakeState.batteryThreshold(defaults)
    }

    private func handleBattery(_ snapshot: LidAwakeBatterySnapshot) {
        lastBattery = snapshot
        safetyReconciler.recordBattery()
        batteryOverride = LidAwakeBatteryPolicy.shouldKeepOverride(
            batteryOverride, onAC: snapshot.onAC)
        guard intent, !applying else { return }
        evaluateBattery(snapshot)
    }

    private func evaluateBattery(_ snapshot: LidAwakeBatterySnapshot) {
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
        if lidSession.handle(lidClosed: closed) { requestAutomaticStop() }
    }

    func requestAutomaticStop() {
        LidAwakeState.setAutomaticStopPending(true, defaults)
        if safetyReconciler.requestAutomaticStop(applying: applying) {
            stop(automaticRetriesRemaining: automaticStopRetries)
        }
    }

    private func applySystemState(
        _ systemActive: Bool,
        intentAfter: Bool,
        suspendedAfter: Bool,
        overrideAfter: Bool,
        sessionAfter: LidAwakeSession,
        configureSessionAfter: Bool,
        automaticRetriesRemaining: Int = 0,
        completion: ((LidAwakeOutcome) -> Void)? = nil
    ) {
        guard !applying else { return }
        systemReadGeneration &+= 1
        systemReadTask?.cancel()
        systemReadTask = nil
        applying = true
        lastError = nil
        let mutationBatteryRevision = safetyReconciler.batteryRevision
        let mutationSessionRevision = sessionRevision
        mutationSequencer.enqueue { [self] in
            let outcome = await self.apply(systemActive: systemActive)
            self.finish(
                outcome,
                systemActive: systemActive,
                intentAfter: intentAfter,
                suspendedAfter: suspendedAfter,
                overrideAfter: overrideAfter,
                sessionAfter: sessionAfter,
                configureSessionAfter: configureSessionAfter,
                automaticRetriesRemaining: automaticRetriesRemaining,
                mutationBatteryRevision: mutationBatteryRevision,
                mutationSessionRevision: mutationSessionRevision,
                completion: completion)
        }
    }

    private func apply(systemActive: Bool) async -> LidAwakeOutcome {
        if let applyOverride { return await applyOverride(systemActive) }
        do {
            try await privilegedClient.setSleepDisabled(systemActive)
            return .applied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func restoreOrphanedState(
        defaults: UserDefaults = SharedDefaults.store,
        readSystemState: @escaping @Sendable () async throws -> Bool = {
            try await LidAwakeSystemStateReader.read()
        },
        applySystemState: (@MainActor @Sendable (Bool) async -> LidAwakeOutcome)? = nil,
        announceChange: @escaping @MainActor @Sendable () -> Void = {
            IPC.post(IPC.Name.lidAwakeChanged)
        }
    ) async -> LidAwakeOutcome {
        let systemActive: Bool
        do {
            systemActive = try await readSystemState()
        } catch {
            return .failed(error.localizedDescription)
        }
        guard systemActive else {
            LidAwakeState.setActive(false, defaults)
            LidAwakeState.setAutomaticStopPending(false, defaults)
            LidAwakeState.setSessionDeadline(nil, defaults)
            announceChange()
            return .applied
        }
        let outcome: LidAwakeOutcome
        if let applySystemState {
            outcome = await applySystemState(false)
        } else {
            let client = LidAwakePrivilegedClient()
            client.register()
            do {
                try await client.setSleepDisabled(false)
                outcome = .applied
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
        switch outcome {
        case .applied:
            LidAwakeState.setActive(false, defaults)
            LidAwakeState.setAutomaticStopPending(false, defaults)
            LidAwakeState.setSessionDeadline(nil, defaults)
        case .failed:
            LidAwakeState.setActive(true, defaults)
        }
        announceChange()
        return outcome
    }

    private func finish(
        _ outcome: LidAwakeOutcome,
        systemActive: Bool,
        intentAfter: Bool,
        suspendedAfter: Bool,
        overrideAfter: Bool,
        sessionAfter: LidAwakeSession,
        configureSessionAfter: Bool,
        automaticRetriesRemaining: Int,
        mutationBatteryRevision: UInt,
        mutationSessionRevision: UInt,
        completion: ((LidAwakeOutcome) -> Void)?
    ) {
        applying = false
        var completesRequest = true
        switch outcome {
        case .applied:
            active = systemActive
            intent = intentAfter
            batterySuspended = suspendedAfter
            batteryOverride = overrideAfter
            if systemActive { displayWakeKeeper.prevent() } else { displayWakeKeeper.allow() }
            let sessionChanged = sessionRevision != mutationSessionRevision
            let resolvedSession = sessionChanged ? LidAwakeState.session(defaults) : sessionAfter
            session = resolvedSession
            if !intentAfter {
                autoOffTimer.cancel()
                lidSession.cancel()
                remaining = nil
                LidAwakeState.setSessionDeadline(nil, defaults)
                LidAwakeState.setAutomaticStopPending(false, defaults)
                safetyReconciler.clearAutomaticStop()
            } else if configureSessionAfter || sessionChanged {
                configureSession(resolvedSession, deadline: nil)
            } else {
                updateRemaining()
            }
            lastError = nil
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            publishState()
        case .failed(let message):
            if automaticRetriesRemaining > 0, !stopped {
                applySystemState(
                    false,
                    intentAfter: false,
                    suspendedAfter: false,
                    overrideAfter: false,
                    sessionAfter: session,
                    configureSessionAfter: false,
                    automaticRetriesRemaining: automaticRetriesRemaining - 1,
                    completion: completion)
                completesRequest = false
            } else {
                if systemActive {
                    active = true
                    intent = intentAfter
                    batterySuspended = false
                    displayWakeKeeper.prevent()
                    if configureSessionAfter {
                        configureSession(sessionAfter, deadline: nil)
                    }
                    LidAwakeState.setActive(true, defaults)
                }
                lastError = message
                announceChange()
                refreshFromSystem()
            }
        }
        guard completesRequest else { return }
        completion?(outcome)
        switch safetyReconciler.followUp(
            stopped: stopped,
            mutationBatteryRevision: mutationBatteryRevision,
            hasBattery: lastBattery != nil)
        {
        case .automaticStop:
            requestAutomaticStop()
        case .battery:
            if let lastBattery { evaluateBattery(lastBattery) }
        case .none:
            break
        }
    }

    private func configureSession(_ session: LidAwakeSession, deadline: Date?) {
        self.session = session
        LidAwakeState.setSession(session, defaults)
        autoOffTimer.cancel()
        lidSession.cancel()
        switch session {
        case .indefinite:
            LidAwakeState.setSessionDeadline(nil, defaults)
        case .fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours:
            let minutes = session.minutes ?? 0
            if let deadline, deadline <= Date() {
                remaining = 0
                LidAwakeState.setAutomaticStopPending(true, defaults)
                requestAutomaticStop()
                return
            }
            let target = deadline ?? Date().addingTimeInterval(TimeInterval(minutes) * 60)
            autoOffTimer.start(deadline: target)
            LidAwakeState.setSessionDeadline(target, defaults)
        case .untilLidReopens:
            LidAwakeState.setSessionDeadline(nil, defaults)
            lidSession.start(lidClosed: lidMonitor.isClosed)
        }
        updateRemaining()
    }

    private func updateRemaining() {
        remaining = autoOffTimer.remaining
        if let deadline = autoOffTimer.deadline {
            LidAwakeState.setSessionDeadline(deadline, defaults)
        }
    }

    private func stopEngine(force: Bool) -> Task<LidAwakeOutcome, Never>? {
        guard !stopped else { return nil }
        stopped = true
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        batteryMonitor.stop()
        lidMonitor.stop()
        displayWakeKeeper.allow()
        systemReadGeneration &+= 1
        systemReadTask?.cancel()
        systemReadTask = nil
        autoOffTimer.cancel()
        lidSession.cancel()
        let shouldRestore = active || batterySuspended || intent || applying
        if force || (shouldRestore && LidAwakeState.restoresOnQuit(defaults)) {
            if shouldRestore {
                LidAwakeState.setAutomaticStopPending(true, defaults)
            }
            return mutationSequencer.enqueueResult { [self] in
                var restorationRequired = shouldRestore
                if force, !restorationRequired, let systemStateReader {
                    do {
                        restorationRequired = try await systemStateReader()
                    } catch {
                        restorationRequired = true
                    }
                }
                guard restorationRequired else {
                    LidAwakeState.setActive(false, self.defaults)
                    LidAwakeState.setAutomaticStopPending(false, self.defaults)
                    LidAwakeState.setSessionDeadline(nil, self.defaults)
                    self.safetyReconciler.clearAutomaticStop()
                    self.announceChange()
                    return .applied
                }
                LidAwakeState.setAutomaticStopPending(true, self.defaults)
                let outcome = await self.apply(systemActive: false)
                switch outcome {
                case .applied:
                    self.active = false
                    self.intent = false
                    self.batterySuspended = false
                    LidAwakeState.setActive(false, self.defaults)
                    LidAwakeState.setAutomaticStopPending(false, self.defaults)
                    LidAwakeState.setSessionDeadline(nil, self.defaults)
                    self.safetyReconciler.clearAutomaticStop()
                    self.announceChange()
                case .failed(let message):
                    self.lastError = message
                    LidAwakeState.setActive(true, self.defaults)
                    self.announceChange()
                }
                return outcome
            }
        } else {
            let preserveSystemState = shouldRestore && !force
            active = false
            intent = false
            batterySuspended = false
            if !preserveSystemState {
                LidAwakeState.setActive(false, defaults)
                announceChange()
            }
            return nil
        }
    }

    private func publishState() {
        LidAwakeState.setActive(active, defaults)
        LidAwakeState.setSession(session, defaults)
        announceChange()
    }
}
