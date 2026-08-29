import AppKit
import EdithKit
import EventKit
import Foundation
import UserNotifications

@MainActor
@Observable
final class FocusRuntime: NSObject {
    private(set) var document = FocusDocument()
    private(set) var activeSession: FocusSession?
    private(set) var history: [FocusHistoryRecord] = []
    private(set) var lastError: String?

    private let storage: FocusStorage
    private let automations: AutomationRuntime
    private var transitionWork: Task<Void, Never>?
    private var transitionGeneration = 0
    private var sessionTimer: Timer?
    private var calendarTimer: Timer?
    private var calendarStore: EKEventStore?
    private var calendarObserver: NSObjectProtocol?
    private var ipcObserver: NSObjectProtocol?
    private var shortcutIDs: Set<UInt32> = []
    private var statusItem: NSStatusItem?

    init(automations: AutomationRuntime, storage: FocusStorage = FocusStorage()) {
        self.automations = automations
        self.storage = storage
        super.init()
        reload()
        recoverSession()
    }

    func reload() {
        do {
            document = try storage.load()
            history = try storage.history()
            lastError = nil
        } catch {
            document = FocusDocument()
            history = []
            lastError = error.localizedDescription
        }
        syncSubscriptions()
        syncStatusItem()
    }

    func profile(matching query: String) -> FocusProfile? {
        let lowered = query.lowercased()
        return document.profiles.first {
            $0.id.uuidString.lowercased() == lowered || $0.name.lowercased() == lowered
        }
    }

    func start(
        _ profile: FocusProfile, durationMinutes: Int? = nil, until: Date? = nil,
        origin: FocusActivationOrigin, meeting: EKEvent? = nil, requestID: String? = nil
    ) {
        guard transitionWork == nil else {
            postResult(
                requestID: requestID, succeeded: false, error: "A focus change is in progress.")
            return
        }
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionWork = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await activate(
                    profile, durationMinutes: durationMinutes, until: until, origin: origin,
                    meeting: meeting)
                guard !Task.isCancelled, transitionGeneration == generation else { return }
                postResult(requestID: requestID, succeeded: true)
            } catch {
                guard !Task.isCancelled, transitionGeneration == generation else { return }
                lastError = error.localizedDescription
                postResult(
                    requestID: requestID, succeeded: false, error: error.localizedDescription)
            }
            if transitionGeneration == generation { transitionWork = nil }
        }
    }

    func start(
        matching query: String, durationMinutes: Int? = nil, until: Date? = nil,
        origin: FocusActivationOrigin, requestID: String? = nil
    ) {
        guard let profile = profile(matching: query) else {
            postResult(
                requestID: requestID, succeeded: false,
                error: "No focus profile matches \(query).")
            return
        }
        start(
            profile, durationMinutes: durationMinutes, until: until, origin: origin,
            requestID: requestID)
    }

    func stop(requestID: String? = nil) {
        guard transitionWork == nil else {
            postResult(
                requestID: requestID, succeeded: false, error: "A focus change is in progress.")
            return
        }
        guard activeSession != nil else {
            postResult(requestID: requestID, succeeded: true)
            return
        }
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionWork = Task { @MainActor [weak self] in
            guard let self else { return }
            let errors = await endActive(outcome: .completed)
            guard !Task.isCancelled, transitionGeneration == generation else { return }
            postResult(
                requestID: requestID, succeeded: errors.isEmpty,
                error: errors.isEmpty ? nil : errors.joined(separator: " "))
            if transitionGeneration == generation { transitionWork = nil }
        }
    }

    func prepareForTermination() async {
        transitionGeneration += 1
        let pending = transitionWork
        pending?.cancel()
        transitionWork = nil
        await pending?.value
        _ = await endActive(outcome: .recovered)
        stopSubscriptions()
    }

    func shutdownForDisable(onFinished: @escaping @MainActor () -> Void = {}) {
        transitionGeneration += 1
        let generation = transitionGeneration
        let pending = transitionWork
        pending?.cancel()
        transitionWork = Task { @MainActor [weak self] in
            guard let self else {
                onFinished()
                return
            }
            await pending?.value
            _ = await endActive(outcome: .recovered)
            stopSubscriptions()
            guard transitionGeneration == generation else { return }
            transitionWork = nil
            onFinished()
        }
    }

    private func activate(
        _ profile: FocusProfile, durationMinutes: Int?, until: Date?,
        origin: FocusActivationOrigin, meeting: EKEvent?
    ) async throws {
        guard profile.isEnabled else { throw FocusRuntimeError.disabled }
        guard activeSession == nil else { throw FocusRuntimeError.alreadyActive }
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            profile.excludedBundleIdentifiers.contains(bundleID)
        {
            throw FocusRuntimeError.excludedApplication(bundleID)
        }
        var configuredSceneIDs = profile.sceneIDs
        if let windowLayoutSceneID = profile.windowLayoutSceneID {
            configuredSceneIDs.append(windowLayoutSceneID)
        }
        if meeting != nil { configuredSceneIDs.append(contentsOf: document.meeting.startSceneIDs) }
        let configuredScenes = try scenes(configuredSceneIDs)
        let appScene = applicationScene(for: profile)
        var startScenes = configuredScenes
        if let appScene { startScenes.insert(appScene, at: 0) }
        let restorationScene = captureRestoration(profile: profile, scenes: startScenes)
        let now = Date()
        let duration = durationMinutes ?? profile.defaultDurationMinutes
        let endsAt =
            meeting?.endDate ?? until
            ?? duration.map {
                now.addingTimeInterval(Double(max(1, $0) * 60))
            }
        let session = FocusSession(
            profileID: profile.id, profileName: profile.name, origin: origin,
            startedAt: now, endsAt: endsAt, restorationScene: restorationScene,
            rollbackSceneIDs: profile.rollbackSceneIDs,
            meetingEndSceneIDs: meeting == nil ? [] : document.meeting.endSceneIDs,
            meetingEventIdentifier: meeting?.eventIdentifier)
        do {
            try await execute(startScenes, origin: origin)
            try Task.checkCancellation()
            activeSession = session
            try storage.saveSession(session)
            scheduleSessionEnd()
            syncStatusItem()
            notify(profile: profile, started: true)
        } catch {
            _ = await restore(session)
            try? storage.append(
                FocusHistoryRecord(
                    sessionID: session.id, profileName: profile.name, origin: origin,
                    startedAt: now, outcome: .failed, detail: error.localizedDescription))
            history = (try? storage.history()) ?? history
            throw error
        }
    }

    private func endActive(outcome: FocusHistoryOutcome) async -> [String] {
        guard let session = activeSession ?? (try? storage.session()) else { return [] }
        sessionTimer?.invalidate()
        sessionTimer = nil
        let errors = await restore(session)
        try? storage.saveSession(nil)
        activeSession = nil
        let resolvedOutcome: FocusHistoryOutcome = errors.isEmpty ? outcome : .failed
        try? storage.append(
            FocusHistoryRecord(
                sessionID: session.id, profileName: session.profileName, origin: session.origin,
                startedAt: session.startedAt, outcome: resolvedOutcome,
                detail: errors.isEmpty ? nil : errors.joined(separator: " ")))
        history = (try? storage.history()) ?? history
        lastError = errors.first
        syncStatusItem()
        if let profile = document.profiles.first(where: { $0.id == session.profileID }) {
            notify(profile: profile, started: false)
        }
        refreshCalendar()
        return errors
    }

    private func restore(_ session: FocusSession) async -> [String] {
        var errors: [String] = []
        for id in session.meetingEndSceneIDs + session.rollbackSceneIDs {
            guard let scene = automations.scene(id: id) else {
                errors.append("Scene \(id) is missing.")
                continue
            }
            do {
                let record = try await automations.executeScene(scene, origin: .app)
                if !record.succeeded { errors.append("\(scene.name) did not finish cleanly.") }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if !session.restorationScene.actions.isEmpty {
            do {
                let record = try await automations.executeScene(
                    session.restorationScene, origin: .app)
                if !record.succeeded { errors.append("Automatic state restoration failed.") }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return errors
    }

    private func scenes(_ ids: [UUID]) throws -> [AutomationScene] {
        try ids.map { id in
            guard let scene = automations.scene(id: id) else {
                throw FocusRuntimeError.missingScene(id)
            }
            return scene
        }
    }

    private func execute(
        _ scenes: [AutomationScene], origin: FocusActivationOrigin
    ) async throws {
        for scene in scenes {
            let record = try await automations.executeScene(
                scene, origin: automationOrigin(origin))
            try Task.checkCancellation()
            guard record.succeeded else { throw FocusRuntimeError.sceneFailed(scene.name) }
        }
    }

    private func applicationScene(for profile: FocusProfile) -> AutomationScene? {
        var actions: [AutomationAction] = []
        for bundleID in profile.launchApplicationIDs {
            actions.append(AutomationAction(operationID: "apps.open", arguments: [bundleID]))
        }
        for bundleID in profile.quitApplicationIDs {
            actions.append(
                AutomationAction(operationID: "apps.quit", arguments: [bundleID, "--yes"]))
        }
        guard !actions.isEmpty else { return nil }
        return AutomationScene(name: "\(profile.name) applications", actions: actions)
    }

    private func captureRestoration(
        profile: FocusProfile, scenes: [AutomationScene]
    ) -> AutomationScene {
        let configuration = ConfigurationExecutor.application
        var capturedKeys: Set<String> = []
        var actions: [AutomationAction] = []
        for action in scenes.flatMap(\.actions).reversed()
        where action.operationID == "config.set" && action.arguments.count >= 2 {
            let key = action.arguments[0]
            guard capturedKeys.insert(key).inserted,
                let definition = try? configuration.definition(for: key)
            else { continue }
            if configuration.isSet(definition) {
                let value = configuration.value(for: definition)
                actions.append(
                    AutomationAction(
                        operationID: "config.set", arguments: [key, configurationText(value)]))
            } else {
                actions.append(
                    AutomationAction(operationID: "config.unset", arguments: [key]))
            }
        }
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for bundleID in profile.launchApplicationIDs.reversed() where !running.contains(bundleID) {
            actions.append(
                AutomationAction(operationID: "apps.quit", arguments: [bundleID, "--yes"]))
        }
        for bundleID in profile.quitApplicationIDs.reversed() where running.contains(bundleID) {
            actions.append(AutomationAction(operationID: "apps.open", arguments: [bundleID]))
        }
        return AutomationScene(
            name: "Restore \(profile.name)", actions: actions,
            errorPolicy: .continueOnError)
    }

    private func configurationText(_ value: JSONValue) -> String {
        switch value {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .array(let values):
            values.compactMap {
                if case .string(let value) = $0 { value } else { nil }
            }.joined(separator: ",")
        case .object: ""
        }
    }

    private func recoverSession() {
        guard let session = try? storage.session() else { return }
        activeSession = session
        if let endsAt = session.endsAt, endsAt <= Date() {
            transitionGeneration += 1
            let generation = transitionGeneration
            transitionWork = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await endActive(outcome: .recovered)
                guard !Task.isCancelled, transitionGeneration == generation else { return }
                transitionWork = nil
            }
        } else {
            scheduleSessionEnd()
            syncStatusItem()
        }
    }

    private func scheduleSessionEnd() {
        sessionTimer?.invalidate()
        guard let endsAt = activeSession?.endsAt else { return }
        sessionTimer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        RunLoop.main.add(sessionTimer!, forMode: .common)
    }

    private func syncSubscriptions() {
        stopSubscriptions(keepSessionTimer: true)
        installShortcuts()
        installIPC()
        if document.meeting.isEnabled,
            SharedDefaults.store.bool(forKey: AppStorageKeys.Tabs.calendarEnabled),
            EKEventStore.authorizationStatus(for: .event) == .fullAccess
        {
            installCalendar()
        }
    }

    private func installShortcuts() {
        for (index, profile) in document.profiles.filter(\.isEnabled).enumerated() {
            guard let shortcut = profile.shortcut else { continue }
            let id = UInt32(20_000 + index)
            shortcutIDs.insert(id)
            GlobalHotKey.set(
                id: id, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers
            ) { [weak self] in
                self?.start(profile, origin: .globalShortcut)
            }
        }
    }

    private func installIPC() {
        ipcObserver = IPC.observe(IPC.Name.requestFocusAction) { [weak self] info in
            Task { @MainActor in self?.handleIPC(info) }
        }
    }

    private func handleIPC(_ info: [AnyHashable: Any]) {
        let requestID = info["requestID"] as? String
        switch info["action"] as? String {
        case "start":
            guard let profile = info["profile"] as? String else {
                postResult(requestID: requestID, succeeded: false, error: "A profile is required.")
                return
            }
            start(
                matching: profile, durationMinutes: info["durationMinutes"] as? Int,
                until: (info["until"] as? String).flatMap(ISO8601DateFormatter().date),
                origin: FocusActivationOrigin(
                    rawValue: info["origin"] as? String ?? "") ?? .commandLine,
                requestID: requestID)
        case "stop":
            stop(requestID: requestID)
        case "status":
            postResult(requestID: requestID, succeeded: true)
        default:
            postResult(requestID: requestID, succeeded: false, error: "Unknown focus action.")
        }
    }

    private func postResult(requestID: String?, succeeded: Bool, error: String? = nil) {
        guard let requestID else { return }
        var info: [String: Any] = ["requestID": requestID, "succeeded": succeeded]
        if let error { info["error"] = error }
        if let session = activeSession {
            info["profile"] = session.profileName
            info["startedAt"] = ISO8601DateFormatter().string(from: session.startedAt)
            if let endsAt = session.endsAt {
                info["endsAt"] = ISO8601DateFormatter().string(from: endsAt)
            }
        }
        IPC.post(IPC.Name.focusActionResult, userInfo: info)
    }

    private func installCalendar() {
        let store = EKEventStore()
        calendarStore = store
        calendarObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendar() }
        }
        refreshCalendar()
    }

    private func refreshCalendar() {
        calendarTimer?.invalidate()
        calendarTimer = nil
        guard activeSession == nil, transitionWork == nil, let store = calendarStore,
            let profileID = document.meeting.profileID,
            let profile = document.profiles.first(where: { $0.id == profileID && $0.isEnabled })
        else { return }
        let now = Date()
        let end = now.addingTimeInterval(60 * 60 * 24)
        let events = store.events(
            matching: store.predicateForEvents(
                withStart: now.addingTimeInterval(-60 * 60), end: end, calendars: nil)
        )
        var currentEvent: EKEvent?
        var nextStart: Date?
        for event in events where event.status != .canceled {
            guard
                FocusMeetingPolicy.includes(
                    meetingCandidate(event), configuration: document.meeting)
            else { continue }
            if event.startDate <= now, event.endDate > now, currentEvent == nil {
                currentEvent = event
            }
            if event.startDate > now {
                if let scheduled = nextStart {
                    nextStart = min(scheduled, event.startDate)
                } else {
                    nextStart = event.startDate
                }
            }
        }
        if let current = currentEvent {
            start(profile, until: current.endDate, origin: .meeting, meeting: current)
            return
        }
        guard let next = nextStart else { return }
        calendarTimer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendar() }
        }
        RunLoop.main.add(calendarTimer!, forMode: .common)
    }

    private func meetingCandidate(_ event: EKEvent) -> FocusMeetingCandidate {
        FocusMeetingCandidate(
            title: event.title ?? "", calendarIdentifier: event.calendar.calendarIdentifier,
            startsAt: event.startDate, endsAt: event.endDate, isAllDay: event.isAllDay,
            isBusy: event.availability != .free,
            hasJoinLink: event.url != nil || (event.location?.contains("://") == true))
    }

    private func stopSubscriptions(keepSessionTimer: Bool = false) {
        if !keepSessionTimer {
            sessionTimer?.invalidate()
            sessionTimer = nil
        }
        calendarTimer?.invalidate()
        calendarTimer = nil
        if let calendarObserver { NotificationCenter.default.removeObserver(calendarObserver) }
        calendarObserver = nil
        calendarStore = nil
        if let ipcObserver {
            IPC.stopObserving(ipcObserver)
        }
        ipcObserver = nil
        for id in shortcutIDs { GlobalHotKey.clear(id: id) }
        shortcutIDs.removeAll()
        removeStatusItem()
    }

    private func syncStatusItem() {
        guard let session = activeSession,
            document.showsStatusItem || session.origin == .meeting
        else {
            removeStatusItem()
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.target = self
            statusItem?.button?.action = #selector(showStatusMenu)
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: session.origin == .meeting ? "video.fill" : "moon.stars.fill",
            accessibilityDescription: "Focus")
        statusItem?.button?.title = session.origin == .meeting ? " Meeting" : ""
        statusItem?.button?.toolTip = "\(session.profileName) is active"
    }

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func showStatusMenu() {
        guard let statusItem, let session = activeSession, let button = statusItem.button else {
            return
        }
        let menu = NSMenu()
        let state = NSMenuItem(title: session.profileName, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let endsAt = session.endsAt {
            let end = NSMenuItem(
                title: "Ends \(endsAt.formatted(date: .omitted, time: .shortened))", action: nil,
                keyEquivalent: "")
            end.isEnabled = false
            menu.addItem(end)
        }
        menu.addItem(.separator())
        let stop = NSMenuItem(
            title: "End Focus", action: #selector(stopFromMenu), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        let open = NSMenuItem(
            title: "Open Edith", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func stopFromMenu() {
        stop()
    }

    @objc private func openFromMenu() {
        MainApp.openDashboard()
    }

    private func notify(profile: FocusProfile, started: Bool) {
        guard profile.notifies,
            SharedDefaults.store.bool(forKey: AppStorageKeys.Permissions.notificationsGranted)
        else { return }
        let content = UNMutableNotificationContent()
        content.title = profile.name
        content.body =
            started ? "Focus profile started." : "Focus profile ended and state restored."
        if started, let focusModeName = profile.focusModeName {
            content.body += " Turn on \(focusModeName) Focus in Control Center if needed."
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func automationOrigin(_ origin: FocusActivationOrigin) -> AutomationRunOrigin {
        switch origin {
        case .app: .app
        case .menuPanel: .menuPanel
        case .commandBar: .commandBar
        case .globalShortcut: .globalShortcut
        case .commandLine: .commandLine
        case .automation, .meeting: .trigger
        }
    }
}

enum FocusRuntimeError: LocalizedError {
    case disabled
    case alreadyActive
    case excludedApplication(String)
    case missingScene(UUID)
    case sceneFailed(String)

    var errorDescription: String? {
        switch self {
        case .disabled: "The focus profile is disabled."
        case .alreadyActive: "A focus session is already active."
        case .excludedApplication(let id): "Focus is excluded while \(id) is active."
        case .missingScene(let id): "Scene \(id) is missing."
        case .sceneFailed(let name): "Scene \(name) did not finish cleanly."
        }
    }
}
