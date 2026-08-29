import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import EdithKit

@MainActor
final class WindowToolsEngine: FeatureModule {
    private struct HotKeySpec {
        let id: UInt32
        let action: WindowLayoutAction
        let codeKey: String
        let modsKey: String
        let defaultCode: Int
    }

    private struct GreenTarget {
        let window: AXUIElement
        let button: AXUIElement
        let origin: CGPoint
    }

    private struct WindowIdentity: Hashable {
        let processIdentifier: pid_t
        let windowNumber: Int
    }

    private struct RuntimeWindow {
        let element: AXUIElement
        let candidate: WorkspaceCandidateWindow
    }

    private var activationObserver: NSObjectProtocol?
    private var requestObserver: NSObjectProtocol?
    private var workspaceRequestObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private var history = WindowFrameHistory<WindowIdentity>()
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var greenTarget: GreenTarget?
    private var restoreTask: Task<Void, Never>?

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard
                    let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                    !Self.isEdith(application)
                else { return }
                self?.lastExternalApplication = application
            }
        }
        requestObserver = IPC.observe(
            IPC.Name.requestWindowLayout,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    guard
                        let raw = info[WindowLayoutRequest.actionKey] as? String,
                        let action = WindowLayoutAction(rawValue: raw)
                    else { return }
                    guard Self.windowToolsEnabled else { return }
                    self?.perform(action)
                }
            })
        workspaceRequestObserver = IPC.observe(
            IPC.Name.requestWorkspaceRestorer,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    guard Self.workspaceRestorerEnabled,
                        let request = WorkspaceRestorerIPC.decode(
                            WorkspaceRestorerRequest.self, from: info)
                    else { return }
                    self?.handle(request)
                }
            })
        if let frontmost = NSWorkspace.shared.frontmostApplication, !Self.isEdith(frontmost) {
            lastExternalApplication = frontmost
        }
        applySettings()
    }

    func applySettings() {
        registerHotKeys()
        let greenButtonOn =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.WindowTools.greenButtonMaximizes) as? Bool ?? true
        if Self.windowToolsEnabled, greenButtonOn, AXIsProcessTrusted() {
            startEventTap()
        } else {
            stopEventTap()
        }
    }

    func shutdown() {
        layoutHotKeys.forEach { GlobalHotKey.clear(id: $0.id) }
        GlobalHotKey.clear(id: GlobalHotKey.ID.workspaceCapture)
        GlobalHotKey.clear(id: GlobalHotKey.ID.workspaceRestore)
        restoreTask?.cancel()
        restoreTask = nil
        stopEventTap()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let requestObserver { IPC.stopObserving(requestObserver) }
        if let workspaceRequestObserver { IPC.stopObserving(workspaceRequestObserver) }
        activationObserver = nil
        requestObserver = nil
        workspaceRequestObserver = nil
        history.removeAll()
    }

    func perform(_ action: WindowLayoutAction) {
        guard AXIsProcessTrusted(), let window = focusedWindow() else { return }
        apply(action, to: window)
    }

    private func handle(_ request: WorkspaceRestorerRequest) {
        if request.operation == .cancel {
            restoreTask?.cancel()
            respond(WorkspaceRestorerResponse(requestID: request.id, ok: true))
            return
        }
        guard restoreTask == nil else {
            respond(
                WorkspaceRestorerResponse(
                    requestID: request.id, ok: false,
                    error: "Another workspace operation is still running."))
            return
        }
        guard AXIsProcessTrusted() else {
            respond(
                WorkspaceRestorerResponse(
                    requestID: request.id, ok: false,
                    error: "Accessibility permission is required to manage workspace windows."))
            return
        }
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { restoreTask = nil }
            do {
                switch request.operation {
                case .capture:
                    let name =
                        request.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !name.isEmpty else { throw WorkspaceRestorerError.invalidName }
                    let profile = captureProfile(name: name)
                    var library = WorkspaceRestorerStore.load()
                    library.upsert(profile)
                    try WorkspaceRestorerStore.save(library)
                    respond(
                        WorkspaceRestorerResponse(
                            requestID: request.id, ok: true, profile: profile))
                case .preview:
                    let profile = try WorkspaceRestorerStore.load().resolve(request.profile ?? "")
                    let plan = makePlan(profile, launchPolicy: request.options.launchPolicy)
                    let run = previewRun(plan)
                    var library = WorkspaceRestorerStore.load()
                    library.record(run)
                    try WorkspaceRestorerStore.save(library)
                    respond(
                        WorkspaceRestorerResponse(
                            requestID: request.id, ok: true, profile: profile, plan: plan,
                            run: run))
                case .restore:
                    let profile = try WorkspaceRestorerStore.load().resolve(request.profile ?? "")
                    let response = await restore(
                        profile, requestID: request.id, options: request.options,
                        preserveRecovery: false)
                    respond(response)
                case .recover:
                    guard let profile = WorkspaceRestorerStore.load().recoveryProfile else {
                        throw WorkspaceRestorerError.notFound("recovery")
                    }
                    let response = await restore(
                        profile, requestID: request.id, options: request.options,
                        preserveRecovery: true)
                    respond(response)
                case .cancel:
                    break
                }
            } catch is CancellationError {
                respond(
                    WorkspaceRestorerResponse(
                        requestID: request.id, ok: false, error: "Workspace restore cancelled."))
            } catch {
                respond(
                    WorkspaceRestorerResponse(
                        requestID: request.id, ok: false, error: error.localizedDescription))
            }
        }
    }

    private func captureProfile(name: String) -> WorkspaceProfile {
        let displays = displaySnapshots()
        let activeBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let applications = workspaceApplications(activeBundleIdentifier: activeBundleIdentifier)
        var snapshots: [WorkspaceWindowSnapshot] = []
        var order = 0
        for application in applications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            for window in elementArrayAttribute(appElement, kAXWindowsAttribute as String) {
                guard let currentAX = frame(of: window) else { continue }
                let current = appKitFrame(from: currentAX)
                guard current.width >= 80, current.height >= 40,
                    let screen = bestScreen(for: current), let displayID = displayID(screen)
                else { continue }
                snapshots.append(
                    WorkspaceWindowSnapshot(
                        bundleIdentifier: bundleIdentifier,
                        applicationName: application.localizedName ?? bundleIdentifier,
                        applicationURL: application.bundleURL?.path,
                        title: stringAttribute(window, kAXTitleAttribute as String) ?? "",
                        role: stringAttribute(window, kAXRoleAttribute as String) ?? "",
                        subrole: stringAttribute(window, kAXSubroleAttribute as String) ?? "",
                        frame: current,
                        minimized: boolAttribute(
                            window, kAXMinimizedAttribute as String, default: false),
                        fullScreen: boolAttribute(window, "AXFullScreen", default: false),
                        displayID: displayID, order: order))
                order += 1
            }
        }
        return WorkspaceProfile(
            name: name, displays: displays, windows: snapshots,
            activeBundleIdentifier: activeBundleIdentifier)
    }

    private func makePlan(
        _ profile: WorkspaceProfile, launchPolicy: WorkspaceLaunchPolicy
    ) -> WorkspaceRestorePlan {
        let runtime = currentRuntimeWindows()
        var candidates: [WorkspaceCandidateWindow] = []
        candidates.reserveCapacity(runtime.count)
        for window in runtime { candidates.append(window.candidate) }
        return WorkspaceRestorerPlanner.plan(
            profile: profile, candidates: candidates, displays: displaySnapshots(),
            launchPolicy: launchPolicy)
    }

    private func previewRun(_ plan: WorkspaceRestorePlan) -> WorkspaceRestoreRun {
        let items = plan.items.map {
            WorkspaceRestoreItemResult(
                windowID: $0.windowID, applicationName: $0.applicationName, title: $0.title,
                confidence: $0.confidence, state: .skipped,
                detail: previewDetail($0))
        }
        return WorkspaceRestoreRun(
            profileID: plan.profileID, profileName: plan.profileName, startedAt: plan.createdAt,
            dryRun: true, cancelled: false, items: items)
    }

    private func previewDetail(_ item: WorkspaceRestorePlanItem) -> String {
        switch item.disposition {
        case .move:
            "Move from display \(item.sourceDisplayID) to \(item.targetDisplayID)."
        case .launch:
            "Launch the missing application, then match and move its window."
        case .skip:
            "No matching window is available and launching is disabled."
        }
    }

    private func restore(
        _ profile: WorkspaceProfile, requestID: UUID, options: WorkspaceRestoreOptions,
        preserveRecovery: Bool
    ) async -> WorkspaceRestorerResponse {
        let startedAt = Date()
        var library = WorkspaceRestorerStore.load()
        if !preserveRecovery {
            library.recoveryProfile = captureProfile(name: "Before \(profile.name)")
            try? WorkspaceRestorerStore.save(library)
        }
        var plan = makePlan(profile, launchPolicy: options.launchPolicy)
        var launchItems: [WorkspaceRestorePlanItem] = []
        for item in plan.items where item.disposition == .launch { launchItems.append(item) }
        if !launchItems.isEmpty {
            var bundleIdentifiers: Set<String> = []
            for saved in profile.windows
            where launchItems.contains(where: { $0.windowID == saved.id }) {
                bundleIdentifiers.insert(saved.bundleIdentifier)
            }
            var orderedBundleIdentifiers = Array(bundleIdentifiers)
            orderedBundleIdentifiers.sort()
            var paths: [String] = []
            for bundleIdentifier in orderedBundleIdentifiers {
                if let path = profile.windows.first(where: {
                    $0.bundleIdentifier == bundleIdentifier
                })?.applicationURL {
                    paths.append(path)
                }
            }
            for start in stride(from: 0, to: paths.count, by: options.concurrency) {
                guard !Task.isCancelled,
                    Date().timeIntervalSince(startedAt) < options.timeout
                else { break }
                let end = min(paths.count, start + options.concurrency)
                let launches: [Task<Void, Never>] = paths[start..<end].map { path in
                    Task { @MainActor in
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = false
                        _ = try? await NSWorkspace.shared.openApplication(
                            at: URL(fileURLWithPath: path), configuration: configuration)
                    }
                }
                for launch in launches { await launch.value }
            }
            while !Task.isCancelled, Date().timeIntervalSince(startedAt) < options.timeout {
                try? await Task.sleep(for: .milliseconds(250))
                plan = makePlan(profile, launchPolicy: .never)
                if plan.items.allSatisfy({ $0.confidence != .missing }) { break }
            }
        }
        var runtime: [String: RuntimeWindow] = [:]
        for window in currentRuntimeWindows() where runtime[window.candidate.token] == nil {
            runtime[window.candidate.token] = window
        }
        var results: [WorkspaceRestoreItemResult] = []
        for item in plan.items {
            if Task.isCancelled {
                results.append(
                    result(item, .cancelled, "Restore was cancelled before this window."))
                continue
            }
            if Date().timeIntervalSince(startedAt) >= options.timeout {
                results.append(result(item, .failed, "Restore timed out before this window."))
                continue
            }
            guard let token = item.candidateToken, let target = runtime[token] else {
                let launched = launchItems.contains { $0.windowID == item.windowID }
                results.append(
                    result(
                        item, launched ? .launched : .skipped,
                        launched
                            ? "The application launched without a matching window."
                            : "No matching window was found."))
                continue
            }
            let restored = applyWorkspaceState(item, to: target.element)
            if restored {
                AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
                results.append(result(item, .restored, "Window state and frame restored."))
            } else {
                results.append(result(item, .failed, "The window refused its restored frame."))
            }
        }
        if !Task.isCancelled, let active = profile.activeBundleIdentifier,
            let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: active
            ).first
        {
            application.activate()
        }
        let run = WorkspaceRestoreRun(
            profileID: profile.id, profileName: profile.name, startedAt: startedAt,
            dryRun: false, cancelled: Task.isCancelled, items: results)
        library = WorkspaceRestorerStore.load()
        library.record(run)
        try? WorkspaceRestorerStore.save(library)
        return WorkspaceRestorerResponse(
            requestID: requestID,
            ok: !run.cancelled && !results.contains(where: { $0.state == .failed }),
            profile: profile, plan: plan, run: run,
            error: results.contains(where: { $0.state == .failed })
                ? "Some workspace windows could not be restored." : nil)
    }

    private func applyWorkspaceState(
        _ item: WorkspaceRestorePlanItem, to window: AXUIElement
    ) -> Bool {
        if boolAttribute(window, "AXFullScreen", default: false), !item.fullScreen {
            _ = setBoolAttribute(false, "AXFullScreen", on: window)
        }
        let moved = setFrame(axFrame(from: item.targetFrame), on: window)
        if item.fullScreen {
            _ = setBoolAttribute(true, "AXFullScreen", on: window)
        }
        _ = setBoolAttribute(item.minimized, kAXMinimizedAttribute as String, on: window)
        return moved
    }

    private func result(
        _ item: WorkspaceRestorePlanItem, _ state: WorkspaceRestoreItemState, _ detail: String
    ) -> WorkspaceRestoreItemResult {
        WorkspaceRestoreItemResult(
            windowID: item.windowID, applicationName: item.applicationName, title: item.title,
            confidence: item.confidence, state: state, detail: detail)
    }

    private func respond(_ response: WorkspaceRestorerResponse) {
        guard let payload = WorkspaceRestorerIPC.payload(response) else { return }
        IPC.post(IPC.Name.workspaceRestorerResult, userInfo: payload)
    }

    private func currentRuntimeWindows() -> [RuntimeWindow] {
        let activeBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let applications = workspaceApplications(activeBundleIdentifier: activeBundleIdentifier)
        var runtime: [RuntimeWindow] = []
        var order = 0
        for application in applications {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            for window in elementArrayAttribute(appElement, kAXWindowsAttribute as String) {
                guard let currentAX = frame(of: window) else { continue }
                let current = appKitFrame(from: currentAX)
                guard current.width >= 80, current.height >= 40,
                    let screen = bestScreen(for: current), let displayID = displayID(screen)
                else { continue }
                let identity = windowIdentity(window)
                let candidate = WorkspaceCandidateWindow(
                    token: "\(identity.processIdentifier):\(identity.windowNumber)",
                    bundleIdentifier: bundleIdentifier,
                    title: stringAttribute(window, kAXTitleAttribute as String) ?? "",
                    role: stringAttribute(window, kAXRoleAttribute as String) ?? "",
                    subrole: stringAttribute(window, kAXSubroleAttribute as String) ?? "",
                    frame: current, displayID: displayID, order: order)
                runtime.append(RuntimeWindow(element: window, candidate: candidate))
                order += 1
            }
        }
        return runtime
    }

    private func workspaceApplications(
        activeBundleIdentifier: String?
    ) -> [NSRunningApplication] {
        let excluded = excludedBundleIdentifiers
        var applications: [NSRunningApplication] = []
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular && !Self.isEdith(application)
            && !excluded.contains(application.bundleIdentifier ?? "")
        {
            applications.append(application)
        }
        applications.sort {
            if $0.bundleIdentifier == activeBundleIdentifier { return true }
            if $1.bundleIdentifier == activeBundleIdentifier { return false }
            return ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }
        return applications
    }

    private func displaySnapshots() -> [WorkspaceDisplaySnapshot] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = displayID(screen) else { return nil }
            return WorkspaceDisplaySnapshot(
                id: id, name: screen.localizedName, frame: screen.frame,
                visibleFrame: screen.visibleFrame, order: index)
        }
    }

    private func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    private var excludedBundleIdentifiers: Set<String> {
        let raw =
            SharedDefaults.store.string(forKey: AppStorageKeys.WorkspaceRestorer.excludedApps)
            ?? ""
        var identifiers: Set<String> = []
        for value in raw.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !identifier.isEmpty { identifiers.insert(identifier) }
        }
        return identifiers
    }

    private static var windowToolsEnabled: Bool {
        SharedDefaults.store.bool(forKey: AppStorageKeys.WindowTools.enabled)
    }

    private static var workspaceRestorerEnabled: Bool {
        SharedDefaults.store.bool(forKey: AppStorageKeys.WorkspaceRestorer.enabled)
    }

    private static var restoreOptions: WorkspaceRestoreOptions {
        let defaults = SharedDefaults.store
        return WorkspaceRestoreOptions(
            launchPolicy: WorkspaceLaunchPolicy(
                rawValue: defaults.string(
                    forKey: AppStorageKeys.WorkspaceRestorer.launchPolicy) ?? "") ?? .never,
            timeout: defaults.object(forKey: AppStorageKeys.WorkspaceRestorer.timeout) as? Double
                ?? 12,
            concurrency: defaults.object(
                forKey: AppStorageKeys.WorkspaceRestorer.concurrency) as? Int ?? 1)
    }

    private var layoutHotKeys: [HotKeySpec] {
        [
            HotKeySpec(
                id: GlobalHotKey.ID.windowLeft, action: .leftHalf,
                codeKey: AppStorageKeys.WindowTools.leftHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.leftHotKeyMods, defaultCode: kVK_LeftArrow),
            HotKeySpec(
                id: GlobalHotKey.ID.windowRight, action: .rightHalf,
                codeKey: AppStorageKeys.WindowTools.rightHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.rightHotKeyMods, defaultCode: kVK_RightArrow),
            HotKeySpec(
                id: GlobalHotKey.ID.windowMaximize, action: .maximize,
                codeKey: AppStorageKeys.WindowTools.maximizeHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.maximizeHotKeyMods, defaultCode: kVK_ANSI_M),
            HotKeySpec(
                id: GlobalHotKey.ID.windowRestore, action: .restore,
                codeKey: AppStorageKeys.WindowTools.restoreHotKeyCode,
                modsKey: AppStorageKeys.WindowTools.restoreHotKeyMods, defaultCode: kVK_ANSI_R),
        ]
    }

    private func registerHotKeys() {
        for spec in layoutHotKeys {
            guard Self.windowToolsEnabled else {
                GlobalHotKey.clear(id: spec.id)
                continue
            }
            let code =
                SharedDefaults.store.object(forKey: spec.codeKey) as? Int ?? spec.defaultCode
            let modifiers =
                SharedDefaults.store.object(forKey: spec.modsKey) as? Int
                ?? (controlKey | optionKey)
            GlobalHotKey.set(id: spec.id, keyCode: code, modifiers: modifiers) { [weak self] in
                MainActor.assumeIsolated { self?.perform(spec.action) }
            }
        }
        registerWorkspaceHotKeys()
    }

    private func registerWorkspaceHotKeys() {
        guard Self.workspaceRestorerEnabled else {
            GlobalHotKey.clear(id: GlobalHotKey.ID.workspaceCapture)
            GlobalHotKey.clear(id: GlobalHotKey.ID.workspaceRestore)
            return
        }
        let captureCode =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.WorkspaceRestorer.captureHotKeyCode) as? Int
            ?? kVK_ANSI_S
        let captureMods =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.WorkspaceRestorer.captureHotKeyMods) as? Int
            ?? (controlKey | optionKey | shiftKey)
        GlobalHotKey.set(
            id: GlobalHotKey.ID.workspaceCapture, keyCode: captureCode, modifiers: captureMods
        ) { [weak self] in
            MainActor.assumeIsolated {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, HH:mm"
                self?.handle(
                    WorkspaceRestorerRequest(
                        operation: .capture, profile: formatter.string(from: Date())))
            }
        }
        let restoreCode =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.WorkspaceRestorer.restoreHotKeyCode) as? Int
            ?? kVK_ANSI_W
        let restoreMods =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.WorkspaceRestorer.restoreHotKeyMods) as? Int
            ?? (controlKey | optionKey | shiftKey)
        GlobalHotKey.set(
            id: GlobalHotKey.ID.workspaceRestore, keyCode: restoreCode, modifiers: restoreMods
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard
                    let latest = WorkspaceRestorerStore.load().profiles.max(by: {
                        $0.capturedAt < $1.capturedAt
                    })
                else { return }
                self?.handle(
                    WorkspaceRestorerRequest(
                        operation: .restore, profile: latest.id.uuidString,
                        options: Self.restoreOptions))
            }
        }
    }

    private func focusedWindow() -> AXUIElement? {
        let running = NSWorkspace.shared.frontmostApplication
        let application = running.flatMap { Self.isEdith($0) ? nil : $0 } ?? lastExternalApplication
        guard let application, !application.isTerminated else { return nil }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return elementAttribute(element, kAXFocusedWindowAttribute as String)
    }

    private func apply(_ action: WindowLayoutAction, to window: AXUIElement) {
        guard let currentAX = frame(of: window) else { return }
        let current = appKitFrame(from: currentAX)
        let key = windowIdentity(window)
        if action == .restore {
            guard let previous = history.last(for: key),
                setFrame(axFrame(from: previous), on: window)
            else { return }
            _ = history.pop(for: key)
            return
        }
        guard let screen = bestScreen(for: current) else { return }
        let target: CGRect?
        if action == .nextDisplay {
            let screens = NSScreen.screens
            guard screens.count > 1, let index = screens.firstIndex(of: screen) else { return }
            let destination = screens[(index + 1) % screens.count].visibleFrame
            target = WindowLayoutGeometry.movedFrame(
                current: current, from: screen.visibleFrame, to: destination)
        } else {
            target = WindowLayoutGeometry.frame(
                for: action, current: current, visibleFrame: screen.visibleFrame)
        }
        guard let target, !close(current, target) else { return }
        if setFrame(axFrame(from: target), on: window) {
            if history.last(for: key).map({ !close($0, current) }) ?? true {
                history.record(current, for: key)
            }
        }
    }

    private func toggleMaximize(_ window: AXUIElement) -> Bool {
        guard let currentAX = frame(of: window) else { return false }
        let current = appKitFrame(from: currentAX)
        let key = windowIdentity(window)
        if let screen = bestScreen(for: current), close(current, screen.visibleFrame),
            let previous = history.last(for: key)
        {
            guard setFrame(axFrame(from: previous), on: window) else { return false }
            _ = history.pop(for: key)
            return true
        }
        guard let screen = bestScreen(for: current) else { return false }
        let target = screen.visibleFrame
        guard !close(current, target), setFrame(axFrame(from: target), on: window) else {
            return false
        }
        if history.last(for: key).map({ !close($0, current) }) ?? true {
            history.record(current, for: key)
        }
        return true
    }

    private func startEventTap() {
        guard eventTap == nil else { return }
        let mask =
            CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    let engine = Unmanaged<WindowToolsEngine>.fromOpaque(info).takeUnretainedValue()
                    return MainActor.assumeIsolated { engine.handleMouse(type, event) }
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes)
        }
        eventTap = nil
        eventSource = nil
        greenTarget = nil
    }

    private func handleMouse(
        _ type: CGEventType, _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard AXIsProcessTrusted() else { return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown {
            guard
                event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                    .isEmpty,
                let target = greenButtonTarget(at: event.location)
            else {
                greenTarget = nil
                return Unmanaged.passUnretained(event)
            }
            greenTarget = target
            return nil
        }
        if type == .leftMouseUp, let target = greenTarget {
            greenTarget = nil
            let delta = hypot(
                event.location.x - target.origin.x, event.location.y - target.origin.y)
            if delta <= 8, let fresh = greenButtonTarget(at: event.location),
                CFEqual(target.window, fresh.window), !toggleMaximize(fresh.window)
            {
                AXUIElementPerformAction(fresh.button, kAXPressAction as CFString)
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func greenButtonTarget(at point: CGPoint) -> GreenTarget? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.35)
        var hit: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
                == .success,
            let hit, let window = topLevelWindow(from: hit),
            !boolAttribute(window, "AXFullScreen", default: false),
            let button = elementAttribute(window, kAXZoomButtonAttribute as String),
            boolAttribute(button, kAXEnabledAttribute as String, default: true),
            let buttonFrame = frame(of: button), buttonFrame.insetBy(dx: -3, dy: -3).contains(point)
        else { return nil }
        return GreenTarget(window: window, button: button, origin: point)
    }

    private func topLevelWindow(from element: AXUIElement) -> AXUIElement? {
        if stringAttribute(element, kAXRoleAttribute as String) == kAXWindowRole as String {
            return element
        }
        if let window = elementAttribute(element, kAXWindowAttribute as String) { return window }
        if let window = elementAttribute(element, kAXTopLevelUIElementAttribute as String) {
            return window
        }
        var current = element
        for _ in 0..<8 {
            guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
                return nil
            }
            if stringAttribute(parent, kAXRoleAttribute as String) == kAXWindowRole as String {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max {
            $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func axFrame(from frame: CGRect) -> CGRect {
        WindowCoordinateGeometry.accessibilityFrame(
            fromAppKit: frame, menuBarScreenTopY: menuBarScreenTopY(fallback: frame.maxY))
    }

    private func appKitFrame(from frame: CGRect) -> CGRect {
        WindowCoordinateGeometry.appKitFrame(
            fromAccessibility: frame, menuBarScreenTopY: menuBarScreenTopY(fallback: frame.maxY))
    }

    private func menuBarScreenTopY(fallback: CGFloat) -> CGFloat {
        let menuBarScreen = NSScreen.screens.first {
            abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
        }
        return (menuBarScreen ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? fallback
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(element, kAXPositionAttribute as String),
            let size = sizeAttribute(element, kAXSizeAttribute as String), size.width > 0,
            size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func setFrame(_ frame: CGRect, on element: AXUIElement) -> Bool {
        guard canSetFrame(on: element) else { return false }
        var origin = frame.origin
        var size = frame.size
        guard let originValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let moved =
            AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, originValue) == .success
        let resized =
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            == .success
        let settled =
            AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, originValue) == .success
        return moved && resized && settled
    }

    private func canSetFrame(on element: AXUIElement) -> Bool {
        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionStatus = AXUIElementIsAttributeSettable(
            element, kAXPositionAttribute as CFString, &positionSettable)
        let sizeStatus = AXUIElementIsAttributeSettable(
            element, kAXSizeAttribute as CFString, &sizeSettable)
        return positionStatus == .success && sizeStatus == .success && positionSettable.boolValue
            && sizeSettable.boolValue
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func elementArrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let elements = value as? [AXUIElement]
        else { return [] }
        return elements
    }

    private func setBoolAttribute(
        _ value: Bool, _ name: String, on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success,
            settable.boolValue
        else { return false }
        return AXUIElementSetAttributeValue(element, name as CFString, value as CFBoolean)
            == .success
    }

    private func windowIdentity(_ window: AXUIElement) -> WindowIdentity {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(window, &processIdentifier)
        var value: CFTypeRef?
        let number: Int
        if AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success,
            let stored = value as? NSNumber
        {
            number = stored.intValue
        } else {
            number = Int(CFHash(window))
        }
        return WindowIdentity(processIdentifier: processIdentifier, windowNumber: number)
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(
        _ element: AXUIElement, _ name: String, default fallback: Bool
    ) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return fallback
        }
        return (value as? NSNumber)?.boolValue ?? fallback
    }

    private func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 4 && abs(lhs.minY - rhs.minY) <= 4
            && abs(lhs.width - rhs.width) <= 4 && abs(lhs.height - rhs.height) <= 4
    }

    private static func isEdith(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier?.hasPrefix("com.pulkit.edith") == true
    }
}

struct WindowFrameHistory<Key: Hashable> {
    private var frames: [Key: [CGRect]] = [:]
    private var order: [Key] = []
    private let maximumWindows: Int
    private let maximumFramesPerWindow: Int

    init(maximumWindows: Int = 32, maximumFramesPerWindow: Int = 8) {
        self.maximumWindows = max(1, maximumWindows)
        self.maximumFramesPerWindow = max(1, maximumFramesPerWindow)
    }

    var windowCount: Int { frames.count }

    func last(for key: Key) -> CGRect? {
        frames[key]?.last
    }

    mutating func record(_ frame: CGRect, for key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
        var values = frames[key, default: []]
        values.append(frame)
        frames[key] = Array(values.suffix(maximumFramesPerWindow))
        while order.count > maximumWindows {
            frames.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func pop(for key: Key) -> CGRect? {
        guard var values = frames[key], let frame = values.popLast() else { return nil }
        if values.isEmpty {
            frames.removeValue(forKey: key)
            order.removeAll { $0 == key }
        } else {
            frames[key] = values
        }
        return frame
    }

    mutating func removeAll() {
        frames.removeAll()
        order.removeAll()
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
