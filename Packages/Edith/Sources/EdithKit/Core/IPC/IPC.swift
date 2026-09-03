import Foundation

public enum IPC {
    public enum Name {
        public static let requestUsageRefresh = Notification.Name(
            "com.pulkit.edith.requestUsageRefresh")
        public static let usageRefreshStarted = Notification.Name(
            "com.pulkit.edith.usageRefreshStarted")
        public static let usageRefreshFinished = Notification.Name(
            "com.pulkit.edith.usageRefreshFinished")
        public static let requestLimitsRefresh = Notification.Name(
            "com.pulkit.edith.requestLimitsRefresh")
        public static let limitsUpdated = Notification.Name("com.pulkit.edith.limitsUpdated")
        public static let quitMainApp = Notification.Name("com.pulkit.edith.quitMainApp")
        public static let updateReadyToInstall = Notification.Name(
            "com.pulkit.edith.updateReadyToInstall")
        public static let settingsChanged = Notification.Name("com.pulkit.edith.settingsChanged")
        public static let requestPermissionsRefresh = Notification.Name(
            "com.pulkit.edith.requestPermissionsRefresh")
        public static let permissionsRefreshed = Notification.Name(
            "com.pulkit.edith.permissionsRefreshed")
        public static let grantCalendar = Notification.Name("com.pulkit.edith.grantCalendar")
        public static let grantNotifications = Notification.Name(
            "com.pulkit.edith.grantNotifications")
        public static let grantAccessibility = Notification.Name(
            "com.pulkit.edith.grantAccessibility")
        public static let grantInputMonitoring = Notification.Name(
            "com.pulkit.edith.grantInputMonitoring")
        public static let grantFullDisk = Notification.Name("com.pulkit.edith.grantFullDisk")
        public static let grantScreenRecording = Notification.Name(
            "com.pulkit.edith.grantScreenRecording")
        public static let grantCamera = Notification.Name("com.pulkit.edith.grantCamera")
        public static let requestTestNotification = Notification.Name(
            "com.pulkit.edith.requestTestNotification")
        public static let clipboardChanged = Notification.Name("com.pulkit.edith.clipboardChanged")
        public static let requestColorPick = Notification.Name(
            "com.pulkit.edith.requestColorPick")
        public static let requestEmojiPanel = Notification.Name(
            "com.pulkit.edith.requestEmojiPanel")
        public static let requestEmojiInsert = Notification.Name(
            "com.pulkit.edith.requestEmojiInsert")
        public static let emojiInsertResult = Notification.Name(
            "com.pulkit.edith.emojiInsertResult")
        public static let shelfChanged = Notification.Name("com.pulkit.edith.shelfChanged")
        public static let shelfOperation = Notification.Name("com.pulkit.edith.shelfOperation")
        public static let shelfOperationResult = Notification.Name(
            "com.pulkit.edith.shelfOperationResult")
        public static let machinesChanged = Notification.Name("com.pulkit.edith.machinesChanged")
        public static let requestMachineTerminalBroadcast = Notification.Name(
            "com.pulkit.edith.requestMachineTerminalBroadcast")
        public static let machineTerminalBroadcastResult = Notification.Name(
            "com.pulkit.edith.machineTerminalBroadcastResult")
        public static let downloadQueueChanged = Notification.Name(
            "com.pulkit.edith.downloadQueueChanged")
        public static let requestQuitApps = Notification.Name(
            "com.pulkit.edith.requestQuitApps")
        public static let quitAppsResult = Notification.Name(
            "com.pulkit.edith.quitAppsResult")
        public static let requestFinderUndo = Notification.Name(
            "com.pulkit.edith.requestFinderUndo")
        public static let requestDownloadCancel = Notification.Name(
            "com.pulkit.edith.requestDownloadCancel")
        public static let finderUndoResult = Notification.Name(
            "com.pulkit.edith.finderUndoResult")
        public static let presenterAutoActiveChanged = Notification.Name(
            "com.pulkit.edith.presenterAutoActiveChanged")
        public static let musicCommand = Notification.Name("com.pulkit.edith.musicCommand")
        public static let nowPlayingCommand = Notification.Name(
            "com.pulkit.edith.nowPlayingCommand")
        public static let nowPlayingState = Notification.Name("com.pulkit.edith.nowPlayingState")
        public static let requestNowPlayingState = Notification.Name(
            "com.pulkit.edith.requestNowPlayingState")
        public static let musicState = Notification.Name("com.pulkit.edith.musicState")
        public static let requestMusicState = Notification.Name(
            "com.pulkit.edith.requestMusicState")
        public static let musicLevel = Notification.Name("com.pulkit.edith.musicLevel")
        public static let requestMusicLevels = Notification.Name(
            "com.pulkit.edith.requestMusicLevels")
        public static let requestKeyboardClean = Notification.Name(
            "com.pulkit.edith.requestKeyboardClean")
        public static let keyboardCleanResult = Notification.Name(
            "com.pulkit.edith.keyboardCleanResult")
        public static let openPanel = Notification.Name("com.pulkit.edith.openPanel")
        public static let permissionHintDue = Notification.Name(
            "com.pulkit.edith.permissionHintDue")
        public static let presentNotification = Notification.Name(
            "com.pulkit.edith.presentNotification")
        public static let musicFolderChanged = Notification.Name(
            "com.pulkit.edith.musicFolderChanged")
        public static let musicFavouritesChanged = Notification.Name(
            "com.pulkit.edith.musicFavouritesChanged")
        public static let musicRevealFolder = Notification.Name(
            "com.pulkit.edith.musicRevealFolder")
        public static let presenterPauseAuto = Notification.Name(
            "com.pulkit.edith.presenterPauseAuto")
        public static let requestLidAwakeAction = Notification.Name(
            "com.pulkit.edith.requestLidAwakeAction")
        public static let lidAwakeActionResult = Notification.Name(
            "com.pulkit.edith.lidAwakeActionResult")
        public static let lidAwakeChanged = Notification.Name("com.pulkit.edith.lidAwakeChanged")
        public static let requestUpdateCheck = Notification.Name(
            "com.pulkit.edith.requestUpdateCheck")
        public static let updateCheckFinished = Notification.Name(
            "com.pulkit.edith.updateCheckFinished")
        public static let requestCalendarEvents = Notification.Name(
            "com.pulkit.edith.requestCalendarEvents")
        public static let calendarEvents = Notification.Name("com.pulkit.edith.calendarEvents")
        public static let requestReveal = Notification.Name("com.pulkit.edith.requestReveal")
        public static let revealResult = Notification.Name("com.pulkit.edith.revealResult")
        public static let requestWindowSnapshot = Notification.Name(
            "com.pulkit.edith.requestWindowSnapshot")
        public static let windowSnapshotResult = Notification.Name(
            "com.pulkit.edith.windowSnapshotResult")
        public static let requestAppDiagnostics = Notification.Name(
            "com.pulkit.edith.requestAppDiagnostics")
        public static let appDiagnostics = Notification.Name(
            "com.pulkit.edith.appDiagnostics")
        public static let requestQuinjetSessionOperation = Notification.Name(
            "com.pulkit.edith.requestQuinjetSessionOperation")
        public static let quinjetSessionOperationResult = Notification.Name(
            "com.pulkit.edith.quinjetSessionOperationResult")
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

    init(fallback: NSObjectProtocol?) {
        self.fallback = fallback
    }

    func attach(busSubscription: AgentBusSubscription?) {
        lock.lock()
        let discard = cancelled
        if !discard { self.busSubscription = busSubscription }
        lock.unlock()
        if discard { busSubscription?.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let subscription = busSubscription
        let observer = fallback
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
        work.async {
            guard (try? AgentClient.shared.verifyHandshake()) != nil else { return }
            state.enable()
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
        let observation = IPCObservation(fallback: fallback)
        IPCObservationRegistry.shared.retain(observation)
        guard state.shouldAttempt() else { return observation }
        work.async {
            guard state.shouldAttempt() else { return }
            let subscription = try? AgentClient.shared.subscribeBus(channel: channel) { userInfo in
                DispatchQueue.main.async { deliver(userInfo) }
            }
            if subscription == nil { state.recordFailure() }
            observation.attach(busSubscription: subscription)
        }
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
