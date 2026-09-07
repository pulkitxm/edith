import AppKit
import EdithKit
import EventKit
import Foundation

@MainActor
@Observable
final class AutomationRuntime {
    private(set) var document = AutomationDocument()
    private(set) var history: [AutomationRunRecord] = []
    private(set) var activeSceneIDs: Set<UUID> = []
    private(set) var lastError: String?
    private(set) var subscribedKinds: Set<AutomationTriggerKind> = []

    private let storage: AutomationStorage
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var calendarTimer: Timer?
    private var calendarStore: EKEventStore?
    private var runTasks: [UUID: Task<Void, Never>] = [:]
    private var shortcutIDs: Set<UInt32> = []
    private var lastDisplayCount = NSScreen.screens.count

    init(storage: AutomationStorage = AutomationStorage()) {
        self.storage = storage
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
        kinds.subtract([.schedule, .network, .power, .battery])
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
                activeSceneIDs.insert(scene.id)
                let record = try await AgentAutomationClient.run(
                    AgentAutomationRunRequest(
                        sceneID: scene.id, origin: origin, automationID: automationID,
                        grantedPermissions: grantedPermissions()))
                activeSceneIDs.remove(scene.id)
                history = (try? storage.history()) ?? history
                postResult(record, requestID: requestID)
                runTasks[scene.id] = nil
            } catch {
                activeSceneIDs.remove(scene.id)
                lastError = error.localizedDescription
                postFailure(error.localizedDescription, scene: scene, requestID: requestID)
                runTasks[scene.id] = nil
            }
        }
        runTasks[scene.id] = task
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

    }

    func shutdown() {
        stopSubscriptions()
        for task in runTasks.values { task.cancel() }
        runTasks.removeAll()
        activeSceneIDs.removeAll()
    }

    private func syncSubscriptions() {
        stopSubscriptions()
        let calendarEnabled =
            ExtensionRegistry.entry("calendar")?.isEnabled(in: SharedDefaults.store) == true
        subscribedKinds = Self.requiredSubscriptions(
            for: document, calendarEnabled: calendarEnabled)
        if subscribedKinds.contains(.application) { installApplications() }
        if subscribedKinds.contains(.display) { installDisplays() }
        if subscribedKinds.contains(.screen) { installScreen() }
        if subscribedKinds.contains(.wake) { installWake() }
        if subscribedKinds.contains(.calendar) { installCalendar() }
        installShortcuts()
        installIPC()
    }

    private func stopSubscriptions() {
        calendarTimer?.invalidate()
        calendarTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for token in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        distributedObservers.removeAll()
        calendarStore = nil
        for id in shortcutIDs { GlobalHotKey.clear(id: id) }
        shortcutIDs.removeAll()
        subscribedKinds.removeAll()
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

}
