import AppKit
import EdithKit
import EventKit
import Foundation
import IOKit.ps
import Network
import UserNotifications

@MainActor
@Observable
final class AutomationRuntime {
    private(set) var document = AutomationDocument()
    private(set) var history: [AutomationRunRecord] = []
    private(set) var activeSceneIDs: Set<UUID> = []
    private(set) var lastError: String?
    private(set) var subscribedKinds: Set<AutomationTriggerKind> = []

    private let storage: AutomationStorage
    private let executor: AutomationExecutor
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var scheduleTimer: Timer?
    private var calendarTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var calendarStore: EKEventStore?
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var activeRunIDs: [UUID: UUID] = [:]
    private var shortcutIDs: Set<UInt32> = []
    private var lastPower: AutomationPowerSource?
    private var lastBattery: Int?
    private var lastDisplayCount = NSScreen.screens.count
    private var lastNetwork: AutomationNetworkState?

    init(storage: AutomationStorage = AutomationStorage()) {
        self.storage = storage
        let executable = Self.edExecutable()
        executor = AutomationExecutor(
            runner: { command in
                try await AutomationCommandProcess.run(executable: executable, arguments: command)
            }, storage: storage)
        reload()
    }

    static func requiredSubscriptions(
        for document: AutomationDocument, calendarEnabled: Bool
    ) -> Set<AutomationTriggerKind> {
        var kinds: Set<AutomationTriggerKind> = []
        for automation in document.automations where automation.isEnabled {
            kinds.insert(automation.trigger.kind)
        }
        if !calendarEnabled { kinds.remove(.calendar) }
        return kinds
    }

    func reload() {
        do {
            document = try storage.load()
            history = try storage.history()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            document = AutomationDocument()
            history = []
        }
        syncSubscriptions()
    }

    func runScene(
        _ scene: AutomationScene, origin: AutomationRunOrigin, automationID: UUID? = nil,
        requestID: String? = nil
    ) {
        guard runTasks[scene.id] == nil else {
            postFailure(
                AutomationExecutionError.alreadyRunning.localizedDescription,
                scene: scene,
                requestID: requestID)
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let record = try await executeScene(
                    scene, origin: origin, automationID: automationID)
                postResult(record, requestID: requestID)
                runTasks[scene.id] = nil
            } catch {
                activeRunIDs[scene.id] = nil
                activeSceneIDs.remove(scene.id)
                lastError = error.localizedDescription
                postFailure(error.localizedDescription, scene: scene, requestID: requestID)
                runTasks[scene.id] = nil
            }
        }
        runTasks[scene.id] = task
    }

    func scene(id: UUID) -> AutomationScene? {
        document.scenes.first { $0.id == id }
    }

    func executeScene(
        _ scene: AutomationScene, origin: AutomationRunOrigin,
        automationID: UUID? = nil
    ) async throws -> AutomationRunRecord {
        guard !activeSceneIDs.contains(scene.id) else {
            throw AutomationExecutionError.alreadyRunning
        }
        let runID = try await executor.start(
            scene: scene, automationID: automationID, origin: origin,
            grantedPermissions: grantedPermissions())
        activeRunIDs[scene.id] = runID
        activeSceneIDs.insert(scene.id)
        defer {
            activeRunIDs[scene.id] = nil
            activeSceneIDs.remove(scene.id)
        }
        guard let record = await executor.wait(for: runID) else {
            throw AutomationExecutionError.alreadyRunning
        }
        history = (try? storage.history()) ?? history
        if scene.notifiesOnCompletion { notify(record) }
        return record
    }

    func runScene(
        matching query: String, origin: AutomationRunOrigin, requestID: String? = nil
    ) {
        let lowered = query.lowercased()
        guard
            let scene = document.scenes.first(where: {
                $0.id.uuidString.lowercased() == lowered || $0.name.lowercased() == lowered
            })
        else {
            postFailure("No scene matches \(query).", scene: nil, requestID: requestID)
            return
        }
        runScene(scene, origin: origin, requestID: requestID)
    }

    func cancel(sceneID: UUID) {
        runTasks[sceneID]?.cancel()
        if let runID = activeRunIDs[sceneID] {
            Task { await executor.cancel(runID) }
        }
    }

    func shutdown() {
        stopSubscriptions()
        for task in runTasks.values { task.cancel() }
        runTasks.removeAll()
        activeRunIDs.removeAll()
        activeSceneIDs.removeAll()
        Task { await executor.cancelAll() }
    }

    private func syncSubscriptions() {
        stopSubscriptions()
        let calendarEnabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.calendarEnabled)
        subscribedKinds = Self.requiredSubscriptions(
            for: document, calendarEnabled: calendarEnabled)
        if subscribedKinds.contains(.schedule) { installSchedule() }
        if subscribedKinds.contains(.application) { installApplications() }
        if subscribedKinds.contains(.power) || subscribedKinds.contains(.battery) { installPower() }
        if subscribedKinds.contains(.display) { installDisplays() }
        if subscribedKinds.contains(.screen) { installScreen() }
        if subscribedKinds.contains(.wake) { installWake() }
        if subscribedKinds.contains(.network) { installNetwork() }
        if subscribedKinds.contains(.calendar) { installCalendar() }
        installShortcuts()
        installIPC()
    }

    private func stopSubscriptions() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        calendarTimer?.invalidate()
        calendarTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        distributedObservers.removeAll()
        networkMonitor?.cancel()
        networkMonitor = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
        calendarStore = nil
        for id in shortcutIDs { GlobalHotKey.clear(id: id) }
        shortcutIDs.removeAll()
        subscribedKinds.removeAll()
    }

    private func installSchedule() {
        let now = Date()
        let calendar = Calendar.current
        let dates = document.automations.compactMap { automation -> Date? in
            guard automation.isEnabled,
                case let .schedule(hour, minute, weekdays) = automation.trigger
            else { return nil }
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime
            ).flatMap { date in
                weekdays.isEmpty
                    || weekdays.contains(
                        AutomationWeekday(rawValue: calendar.component(.weekday, from: date))!)
                    ? date
                    : nextWeekdayDate(after: date, hour: hour, minute: minute, weekdays: weekdays)
            }
        }
        guard let fireDate = dates.min() else { return }
        scheduleTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireSchedules(at: fireDate)
                self?.installSchedule()
            }
        }
        RunLoop.main.add(scheduleTimer!, forMode: .common)
    }

    private func nextWeekdayDate(
        after date: Date, hour: Int, minute: Int, weekdays: Set<AutomationWeekday>
    ) -> Date? {
        let calendar = Calendar.current
        for offset in 1...7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date) else {
                continue
            }
            let weekday = AutomationWeekday(rawValue: calendar.component(.weekday, from: candidate))
            if let weekday, weekdays.contains(weekday) {
                return calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: candidate)
            }
        }
        return nil
    }

    private func fireSchedules(at date: Date) {
        let calendar = Calendar.current
        fireRules { trigger in
            guard case let .schedule(hour, minute, weekdays) = trigger else { return false }
            let weekday = AutomationWeekday(rawValue: calendar.component(.weekday, from: date))
            return calendar.component(.hour, from: date) == hour
                && calendar.component(.minute, from: date) == minute
                && (weekdays.isEmpty || weekday.map(weekdays.contains) == true)
        }
    }

    private func installApplications() {
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            self?.fireApplication(note, event: .launched)
        }
        observe(center, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            self?.fireApplication(note, event: .terminated)
        }
    }

    private func fireApplication(_ note: Notification, event: AutomationApplicationEvent) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleIdentifier = app.bundleIdentifier
        else { return }
        fireRules { trigger in
            guard case .application(let expected, let expectedEvent) = trigger else { return false }
            return expectedEvent == event && expected == bundleIdentifier
        }
    }

    private func installPower() {
        let snapshot = powerSnapshot()
        lastPower = snapshot.source
        lastBattery = snapshot.battery
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        powerSource = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let runtime = Unmanaged<AutomationRuntime>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in runtime.powerChanged() }
            }, context)?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode)
        }
    }

    private func powerChanged() {
        let current = powerSnapshot()
        if current.source != lastPower {
            fireRules { trigger in
                guard case .powerSource(let source) = trigger else { return false }
                return source == current.source
            }
        }
        if let previous = lastBattery, let battery = current.battery {
            fireRules { trigger in
                guard case .battery(let level, let direction) = trigger else { return false }
                switch direction {
                case .fallsBelow: return previous > level && battery <= level
                case .risesAbove: return previous < level && battery >= level
                }
            }
        }
        lastPower = current.source
        lastBattery = current.battery
    }

    private func powerSnapshot() -> (source: AutomationPowerSource?, battery: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil) }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any]
            else { continue }
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let percent = description[kIOPSCurrentCapacityKey as String] as? Int
            return (state == kIOPSACPowerValue ? .adapter : .battery, percent)
        }
        return (nil, nil)
    }

    private func installDisplays() {
        lastDisplayCount = NSScreen.screens.count
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
            [weak self] _ in
            guard let self else { return }
            let count = NSScreen.screens.count
            let event: AutomationDisplayEvent = count > lastDisplayCount ? .attached : .detached
            if count != lastDisplayCount {
                fireRules {
                    if case .display(let value) = $0 { return value == event }
                    return false
                }
            }
            lastDisplayCount = count
        }
    }

    private func installScreen() {
        let center = DistributedNotificationCenter.default()
        for (name, event) in [
            (Notification.Name("com.apple.screenIsLocked"), AutomationScreenEvent.locked),
            (Notification.Name("com.apple.screenIsUnlocked"), AutomationScreenEvent.unlocked),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    self?.fireRules {
                        if case .screen(let value) = $0 { return value == event }
                        return false
                    }
                }
            }
            distributedObservers.append(token)
        }
    }

    private func installWake() {
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) {
            [weak self] _ in
            self?.fireRules { if case .wake = $0 { true } else { false } }
        }
    }

    private func installNetwork() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let state: AutomationNetworkState =
                path.status == .satisfied ? .reachable : .unreachable
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastNetwork = state }
                guard self.lastNetwork != nil, self.lastNetwork != state else { return }
                self.fireRules {
                    if case .network(let value) = $0 { return value == state }
                    return false
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.pulkit.edith.automations.network"))
    }

    private func installCalendar() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let store = EKEventStore()
        calendarStore = store
        observe(NotificationCenter.default, .EKEventStoreChanged) { [weak self] _ in
            self?.scheduleCalendar()
        }
        scheduleCalendar()
    }

    private func scheduleCalendar() {
        calendarTimer?.invalidate()
        guard let store = calendarStore else { return }
        let now = Date()
        let end = now.addingTimeInterval(60 * 60 * 24 * 14)
        let events = store.events(
            matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
        let dates = events.flatMap { [$0.startDate, $0.endDate] }.filter { $0 > now }
        guard let fireDate = dates.min() else { return }
        calendarTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.fireCalendar(at: fireDate)
                self?.scheduleCalendar()
            }
        }
        RunLoop.main.add(calendarTimer!, forMode: .common)
    }

    private func fireCalendar(at date: Date) {
        guard let store = calendarStore else { return }
        let window: TimeInterval = 2
        let events = store.events(
            matching: store.predicateForEvents(
                withStart: date.addingTimeInterval(-window),
                end: date.addingTimeInterval(window), calendars: nil))
        fireRules { trigger in
            guard case .calendar(let contains, let phase) = trigger else { return false }
            return events.contains { event in
                guard let boundary = phase == .starts ? event.startDate : event.endDate else {
                    return false
                }
                let timeMatches = abs(boundary.timeIntervalSince(date)) <= window
                let titleMatches: Bool
                if let contains {
                    titleMatches = event.title.localizedCaseInsensitiveContains(contains)
                } else {
                    titleMatches = true
                }
                return timeMatches && titleMatches
            }
        }
    }

    private func installShortcuts() {
        for (index, scene) in document.scenes.filter(\.isEnabled).enumerated() {
            guard let shortcut = scene.shortcut else { continue }
            let id = UInt32(10_000 + index)
            shortcutIDs.insert(id)
            GlobalHotKey.set(
                id: id, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers
            ) { [weak self] in
                self?.runScene(scene, origin: .globalShortcut)
            }
        }
    }

    private func installIPC() {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: IPC.Name.requestAutomationScene, object: nil, queue: .main
        ) { [weak self] note in
            guard let query = note.userInfo?["scene"] as? String else { return }
            let origin =
                AutomationRunOrigin(
                    rawValue: note.userInfo?["origin"] as? String ?? "") ?? .app
            Task { @MainActor in
                self?.runScene(
                    matching: query, origin: origin,
                    requestID: note.userInfo?["requestID"] as? String)
            }
        }
        distributedObservers.append(token)
    }

    private func fireRules(_ matches: (AutomationTrigger) -> Bool) {
        for automation in document.automations
        where automation.isEnabled && matches(automation.trigger) {
            guard let scene = document.scenes.first(where: { $0.id == automation.sceneID }) else {
                continue
            }
            runScene(scene, origin: .trigger, automationID: automation.id)
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        using handler: @escaping @MainActor @Sendable (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            Task { @MainActor in handler(note) }
        }
        observers.append((center, token))
    }

    private func grantedPermissions() -> Set<AutomationPermission> {
        let values = PermissionsStatus.granted
        return Set(
            AutomationPermission.allCases.filter { permission in
                values.first { $0.key.rawValue == permission.rawValue }?.value == true
            })
    }

    private func notify(_ record: AutomationRunRecord) {
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.Permissions.notificationsGranted)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = record.sceneName
        content.body = record.succeeded ? "Scene completed." : "Scene finished with an error."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }

    private func postResult(_ record: AutomationRunRecord, requestID: String?) {
        guard let requestID else { return }
        IPC.post(
            IPC.Name.automationSceneResult,
            userInfo: [
                "requestID": requestID, "scene": record.sceneName,
                "succeeded": record.succeeded,
            ])
    }

    private func postFailure(_ message: String, scene: AutomationScene?, requestID: String?) {
        guard let requestID else { return }
        IPC.post(
            IPC.Name.automationSceneResult,
            userInfo: [
                "requestID": requestID, "scene": scene?.name ?? "", "succeeded": false,
                "error": message,
            ])
    }

    private static func edExecutable() -> URL {
        let bundleRoot = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundled = bundleRoot.appendingPathComponent("Contents/MacOS/ed")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
            "ed")
        return sibling ?? URL(fileURLWithPath: "/usr/local/bin/ed")
    }
}
