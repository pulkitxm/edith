import Foundation

public enum IPC {
    public enum Name {
        public static let requestUsageRefresh = IPC.scopedName(
            "com.pulkit.edith.requestUsageRefresh")
        public static let usageRefreshStarted = IPC.scopedName(
            "com.pulkit.edith.usageRefreshStarted")
        public static let usageRefreshFinished = IPC.scopedName(
            "com.pulkit.edith.usageRefreshFinished")
        public static let requestLimitsRefresh = IPC.scopedName(
            "com.pulkit.edith.requestLimitsRefresh")
        public static let limitsUpdated = IPC.scopedName("com.pulkit.edith.limitsUpdated")
        public static let quitMainApp = IPC.scopedName("com.pulkit.edith.quitMainApp")
        public static let updateReadyToInstall = IPC.scopedName(
            "com.pulkit.edith.updateReadyToInstall")
        public static let settingsChanged = IPC.scopedName("com.pulkit.edith.settingsChanged")
        public static let requestPermissionsRefresh = IPC.scopedName(
            "com.pulkit.edith.requestPermissionsRefresh")
        public static let permissionsRefreshed = IPC.scopedName(
            "com.pulkit.edith.permissionsRefreshed")
        public static let grantCalendar = IPC.scopedName("com.pulkit.edith.grantCalendar")
        public static let grantNotifications = IPC.scopedName(
            "com.pulkit.edith.grantNotifications")
        public static let grantAccessibility = IPC.scopedName(
            "com.pulkit.edith.grantAccessibility")
        public static let grantInputMonitoring = IPC.scopedName(
            "com.pulkit.edith.grantInputMonitoring")
        public static let grantFullDisk = IPC.scopedName("com.pulkit.edith.grantFullDisk")
        public static let grantScreenRecording = IPC.scopedName(
            "com.pulkit.edith.grantScreenRecording")
        public static let grantCamera = IPC.scopedName("com.pulkit.edith.grantCamera")
        public static let requestTestNotification = IPC.scopedName(
            "com.pulkit.edith.requestTestNotification")
        public static let clipboardChanged = IPC.scopedName("com.pulkit.edith.clipboardChanged")
        public static let requestColorPick = IPC.scopedName(
            "com.pulkit.edith.requestColorPick")
        public static let requestEmojiPanel = IPC.scopedName(
            "com.pulkit.edith.requestEmojiPanel")
        public static let requestEmojiInsert = IPC.scopedName(
            "com.pulkit.edith.requestEmojiInsert")
        public static let emojiInsertResult = IPC.scopedName(
            "com.pulkit.edith.emojiInsertResult")
        public static let shelfChanged = IPC.scopedName("com.pulkit.edith.shelfChanged")
        public static let shelfOperation = IPC.scopedName("com.pulkit.edith.shelfOperation")
        public static let shelfOperationResult = IPC.scopedName(
            "com.pulkit.edith.shelfOperationResult")
        public static let machinesChanged = IPC.scopedName("com.pulkit.edith.machinesChanged")
        public static let requestMachineTerminalBroadcast = IPC.scopedName(
            "com.pulkit.edith.requestMachineTerminalBroadcast")
        public static let machineTerminalBroadcastResult = IPC.scopedName(
            "com.pulkit.edith.machineTerminalBroadcastResult")
        public static let requestQuitApps = IPC.scopedName(
            "com.pulkit.edith.requestQuitApps")
        public static let quitAppsResult = IPC.scopedName(
            "com.pulkit.edith.quitAppsResult")
        public static let requestFinderUndo = IPC.scopedName(
            "com.pulkit.edith.requestFinderUndo")
        public static let finderUndoResult = IPC.scopedName(
            "com.pulkit.edith.finderUndoResult")
        public static let presenterAutoActiveChanged = IPC.scopedName(
            "com.pulkit.edith.presenterAutoActiveChanged")
        public static let musicCommand = IPC.scopedName("com.pulkit.edith.musicCommand")
        public static let nowPlayingCommand = IPC.scopedName(
            "com.pulkit.edith.nowPlayingCommand")
        public static let nowPlayingState = IPC.scopedName("com.pulkit.edith.nowPlayingState")
        public static let requestNowPlayingState = IPC.scopedName(
            "com.pulkit.edith.requestNowPlayingState")
        public static let musicState = IPC.scopedName("com.pulkit.edith.musicState")
        public static let requestMusicState = IPC.scopedName(
            "com.pulkit.edith.requestMusicState")
        public static let musicLevel = IPC.scopedName("com.pulkit.edith.musicLevel")
        public static let requestMusicLevels = IPC.scopedName(
            "com.pulkit.edith.requestMusicLevels")
        public static let requestKeyboardClean = IPC.scopedName(
            "com.pulkit.edith.requestKeyboardClean")
        public static let keyboardCleanResult = IPC.scopedName(
            "com.pulkit.edith.keyboardCleanResult")
        public static let openPanel = IPC.scopedName("com.pulkit.edith.openPanel")
        public static let permissionHintDue = IPC.scopedName(
            "com.pulkit.edith.permissionHintDue")
        public static let presentNotification = IPC.scopedName(
            "com.pulkit.edith.presentNotification")
        public static let musicFolderChanged = IPC.scopedName(
            "com.pulkit.edith.musicFolderChanged")
        public static let musicFavouritesChanged = IPC.scopedName(
            "com.pulkit.edith.musicFavouritesChanged")
        public static let musicRevealFolder = IPC.scopedName(
            "com.pulkit.edith.musicRevealFolder")
        public static let presenterPauseAuto = IPC.scopedName(
            "com.pulkit.edith.presenterPauseAuto")
        public static let requestLidAwakeAction = IPC.scopedName(
            "com.pulkit.edith.requestLidAwakeAction")
        public static let lidAwakeActionResult = IPC.scopedName(
            "com.pulkit.edith.lidAwakeActionResult")
        public static let lidAwakeChanged = IPC.scopedName("com.pulkit.edith.lidAwakeChanged")
        public static let requestUpdateCheck = IPC.scopedName(
            "com.pulkit.edith.requestUpdateCheck")
        public static let updateCheckFinished = IPC.scopedName(
            "com.pulkit.edith.updateCheckFinished")
        public static let requestCalendarEvents = IPC.scopedName(
            "com.pulkit.edith.requestCalendarEvents")
        public static let calendarEvents = IPC.scopedName("com.pulkit.edith.calendarEvents")
        public static let requestReveal = IPC.scopedName("com.pulkit.edith.requestReveal")
        public static let revealResult = IPC.scopedName("com.pulkit.edith.revealResult")
        public static let requestWindowSnapshot = IPC.scopedName(
            "com.pulkit.edith.requestWindowSnapshot")
        public static let windowSnapshotResult = IPC.scopedName(
            "com.pulkit.edith.windowSnapshotResult")
        public static let requestAppDiagnostics = IPC.scopedName(
            "com.pulkit.edith.requestAppDiagnostics")
        public static let appDiagnostics = IPC.scopedName(
            "com.pulkit.edith.appDiagnostics")
        public static let requestQuinjetSessionOperation = IPC.scopedName(
            "com.pulkit.edith.requestQuinjetSessionOperation")
        public static let quinjetSessionOperationResult = IPC.scopedName(
            "com.pulkit.edith.quinjetSessionOperationResult")
    }

    public static func scopedName(
        _ rawValue: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Notification.Name {
        guard
            let namespace = environment["EDITH_AGENT_MACH_SERVICE"]
                ?? environment["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return Notification.Name(rawValue) }
        return Notification.Name(rawValue + ".runtime." + namespace)
    }

    public static func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        var body = userInfo ?? [:]
        body[IPCMessage.idKey] = UUID().uuidString
        IPCTransport.deliverOverAgent(channel: name.rawValue, userInfo: body)
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: body, deliverImmediately: true)
    }

    public static func observe(_ name: Notification.Name, using block: @escaping () -> Void)
        -> NSObjectProtocol
    {
        observe(name, info: { _ in block() })
    }

    public static func observe(
        _ name: Notification.Name, info block: @escaping ([AnyHashable: Any]) -> Void
    ) -> NSObjectProtocol {
        IPCTransport.observe(channel: name.rawValue, name: name, info: block)
    }

    public static func stopObserving(_ token: NSObjectProtocol) {
        if let observation = token as? IPCObservation {
            IPCObservationRegistry.shared.release(observation)
            return
        }
        DistributedNotificationCenter.default().removeObserver(token)
    }
}

public enum IPCMessage {
    public static let idKey = "com.pulkit.edith.ipcID"
}

public final class IPCDeduplicator: @unchecked Sendable {
    public static let capacity = 256

    private let lock = NSLock()
    private var order: [String] = []
    private var seen: Set<String> = []

    public init() {}

    public func accept(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard seen.insert(identifier).inserted else { return false }
        order.append(identifier)
        while order.count > Self.capacity {
            seen.remove(order.removeFirst())
        }
        return true
    }
}

public final class IPCObservationRegistry: @unchecked Sendable {
    public static let shared = IPCObservationRegistry()

    private let lock = NSLock()
    private var observations: [ObjectIdentifier: IPCObservation] = [:]

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observations.count
    }

    public func retain(_ observation: IPCObservation) {
        lock.lock()
        observations[ObjectIdentifier(observation)] = observation
        lock.unlock()
    }

    func activate() {
        lock.lock()
        let pending = Array(observations.values)
        lock.unlock()
        for observation in pending { observation.activate() }
    }

    public func release(_ observation: IPCObservation) {
        lock.lock()
        observations.removeValue(forKey: ObjectIdentifier(observation))
        lock.unlock()
        observation.cancel()
    }
}

public final class IPCObservation: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var busSubscription: AgentBusSubscription?
    private var fallback: NSObjectProtocol?
    private var cancelled = false
    private var subscribing = false
    private var subscribe: (@Sendable () -> AgentBusSubscription?)?

    init(
        fallback: NSObjectProtocol?,
        subscribe: @escaping @Sendable () -> AgentBusSubscription?
    ) {
        self.fallback = fallback
        self.subscribe = subscribe
    }

    func activate() {
        lock.lock()
        guard !cancelled, !subscribing, busSubscription == nil, let subscribe else {
            lock.unlock()
            return
        }
        subscribing = true
        lock.unlock()
        let subscription = subscribe()
        lock.lock()
        subscribing = false
        let discard = cancelled
        if !discard { busSubscription = subscription }
        lock.unlock()
        if discard { subscription?.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let subscription = busSubscription
        let observer = fallback
        subscribe = nil
        busSubscription = nil
        fallback = nil
        lock.unlock()
        subscription?.cancel()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    deinit { cancel() }
}

public enum IPCTransport {
    public static let cooldown: TimeInterval = 30

    static let state = IPCTransportState()

    public static var isEnabled: Bool { state.isEnabled }

    public static func enable() {
        enable(client: .shared, registry: .shared, state: state)
    }

    static func enable(
        client: AgentClient, registry: IPCObservationRegistry, state: IPCTransportState
    ) {
        work.async {
            guard (try? client.verifyHandshake()) != nil else { return }
            state.enable()
            registry.activate()
        }
    }

    public static func disable() {
        state.disable()
    }

    public static func shouldTry(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= cooldown
    }

    static let work = DispatchQueue(label: "com.pulkit.edith.ipc.transport", qos: .utility)

    public static func deliverOverAgent(channel: String, userInfo: [String: Any]) {
        guard state.shouldAttempt(), AgentBusEncoding.isTransportable(userInfo) else { return }
        work.async {
            guard state.shouldAttempt() else { return }
            do {
                try AgentClient.shared.publishBus(channel: channel, userInfo: userInfo)
            } catch {
                state.recordFailure()
            }
        }
    }

    static func observe(
        channel: String, name: Notification.Name,
        info block: @escaping ([AnyHashable: Any]) -> Void
    ) -> NSObjectProtocol {
        let seen = IPCDeduplicator()
        let deliver: @Sendable ([AnyHashable: Any]) -> Void = { info in
            guard seen.accept(info[IPCMessage.idKey] as? String) else { return }
            block(info)
        }
        let fallback = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { note in deliver(note.userInfo ?? [:]) }
        let observation = IPCObservation(fallback: fallback) {
            guard state.shouldAttempt() else { return nil }
            let subscription = try? AgentClient.shared.subscribeBus(channel: channel) { userInfo in
                DispatchQueue.main.async { deliver(userInfo) }
            }
            if subscription == nil { state.recordFailure() }
            return subscription
        }
        IPCObservationRegistry.shared.retain(observation)
        guard state.shouldAttempt() else { return observation }
        work.async { observation.activate() }
        return observation
    }
}

final class IPCTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var lastFailure: Date?

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func enable() {
        lock.lock()
        enabled = true
        lastFailure = nil
        lock.unlock()
    }

    func disable() {
        lock.lock()
        enabled = false
        lock.unlock()
    }

    func shouldAttempt(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        return IPCTransport.shouldTry(lastFailure: lastFailure, now: now)
    }

    func recordFailure(now: Date = Date()) {
        lock.lock()
        lastFailure = now
        lock.unlock()
    }
}
