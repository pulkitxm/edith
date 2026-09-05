import AppKit
import EdithKit
import Foundation

@MainActor
@Observable
final class ClipboardStore: FeatureModule {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var revision = 0
    private(set) var skippedOversizeAt: Date?
    private(set) var mutationError: String?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private nonisolated(unsafe) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var captureTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var activationTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var mutations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private nonisolated(unsafe) var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var mutationTailID: UUID?
    @ObservationIgnored private var captures: [ClipboardCapture] = []
    @ObservationIgnored private var activationGeneration = 0
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var visibility = ClipboardMonitoringState()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var clipboardObserver: NSObjectProtocol?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    private let client: AgentClipboardClient
    private let capturesPasteboard: Bool
    @ObservationIgnored private var history = ClipboardHistoryProjection()

    required convenience init() {
        self.init(client: AgentClipboardClient())
    }

    init(client: AgentClipboardClient, capturesPasteboard: Bool = true) {
        self.client = client
        self.capturesPasteboard = capturesPasteboard
        let dnc = DistributedNotificationCenter.default()
        observers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.visibility.locked = true; self?.updateTimer()
                }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main)
            { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.visibility.locked = false; self?.updateTimer()
                }
            },
        ]
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.visibility.sleeping = true; self?.updateTimer()
                }
            },
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.visibility.sleeping = false; self?.updateTimer()
                }
            },
        ]
        clipboardObserver = IPC.observe(IPC.Name.clipboardChanged) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            Task { @MainActor in
                self?.timer?.cancel(); self?.timer = nil; self?.updateTimer()
            }
        }
        reload()
        updateTimer()
    }

    func shutdown() {
        visibility.enabled = false
        updateTimer()
        refreshTask?.cancel()
        refreshTask = nil
        captureTask?.cancel()
        captureTask = nil
        activationTask?.cancel()
        activationTask = nil
        for task in mutations.values { task.cancel() }
        mutations.removeAll()
        mutationTail?.cancel()
        mutationTail = nil
        mutationTailID = nil
        captures.removeAll()
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        if let clipboardObserver { IPC.stopObserving(clipboardObserver) }
        if let settingsObserver { IPC.stopObserving(settingsObserver) }
        clipboardObserver = nil
        settingsObserver = nil
    }

    private func updateTimer() {
        guard visibility.active, capturesPasteboard else { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let configured =
            SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.checkInterval) as? Double
            ?? ClipboardIndex.defaultCheckInterval
        let interval =
            configured.isFinite
            ? min(60, max(0.25, configured)) : ClipboardIndex.defaultCheckInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !ClipboardPasteboardFilter.shouldSkip(types: (pasteboard.types ?? []).map(\.rawValue))
        else { return }
        let source = NSWorkspace.shared.frontmostApplication
        let defaults = SharedDefaults.store
        let ignored = ClipboardIgnore.parseUserList(
            defaults.string(forKey: AppStorageKeys.Clipboard.ignoredApps) ?? "")
        guard !ClipboardIgnore.isIgnored(bundleID: source?.bundleIdentifier, userList: ignored)
        else { return }
        let options = ClipboardCaptureOptions(
            saveFiles: defaults.object(forKey: AppStorageKeys.Clipboard.saveFiles) as? Bool ?? true,
            saveImages: defaults.object(forKey: AppStorageKeys.Clipboard.saveImages) as? Bool
                ?? true,
            saveText: defaults.object(forKey: AppStorageKeys.Clipboard.saveText) as? Bool ?? true)
        guard let payload = ClipboardPayloadExtractor.extract(from: pasteboard, options: options)
        else { return }
        let maximum = min(
            ClipboardArchive.maximumBlobBytes,
            defaults.object(forKey: AppStorageKeys.Clipboard.maxItemBytes) as? Int
                ?? ClipboardIndex.defaultMaxItemBytes)
        guard payload.data.count <= maximum else { skippedOversizeAt = Date(); return }
        guard captures.count < 8,
            captures.reduce(0, { $0 + $1.data.count }) + payload.data.count <= 32 << 20
        else {
            mutationError =
                "Clipboard storage is unavailable and the pending capture queue is full."
            return
        }
        captures.append(
            ClipboardCapture(
                payload: payload, sourceApp: source?.localizedName,
                sourceBundleID: source?.bundleIdentifier))
        drainCaptures()
    }

    private func drainCaptures() {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            var failures = 0
            while let self, !Task.isCancelled, self.visibility.enabled,
                let capture = self.captures.first
            {
                do {
                    _ = try await self.client.capture(capture)
                    guard !Task.isCancelled else { return }
                    self.captures.removeFirst()
                    self.mutationError = nil
                    failures = 0
                    self.reload()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.mutationError = error.localizedDescription
                    if let error = error as? AgentError, error.kind == .refused {
                        self.captures.removeFirst()
                        continue
                    }
                    failures += 1
                    do { try await Task.sleep(for: .seconds(min(30, 1 << min(5, failures)))) } catch
                    { return }
                }
            }
            guard !Task.isCancelled else { return }
            self?.captureTask = nil
        }
    }

    private func reload() {
        guard visibility.enabled else { return }
        guard mutations.isEmpty else { refreshPending = true; return }
        guard refreshTask == nil else { refreshPending = true; return }
        refreshTask = Task { [weak self] in
            var failures = 0
            repeat {
                self?.refreshPending = false
                do {
                    guard let client = self?.client else { return }
                    let entries = try await client.entries()
                    guard !Task.isCancelled, let self, self.visibility.enabled else { return }
                    self.history.replace(entries)
                    self.adopt(self.history.entries)
                    failures = 0
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.mutationError = error.localizedDescription
                    failures += 1
                    self?.refreshPending = true
                    do { try await Task.sleep(for: .seconds(min(30, 1 << min(5, failures)))) } catch
                    { return }
                }
            } while self?.refreshPending == true && !Task.isCancelled
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
        }
    }

    private func adopt(_ updated: [ClipboardEntry]) {
        let arranged = ClipboardActions.arrange(updated)
        guard arranged != entries else { return }
        entries = arranged
        revision += 1
    }

    func togglePin(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        mutate(.init(entry.pinned ? .unpin : .pin, ids: [id]))
    }

    func clear(_ plan: ClipboardClearPlan) { mutate(.init(.delete, ids: plan.targetIDs)) }
    func delete(_ id: String) { mutate(.init(.delete, ids: [id])) }
    func dismissMutationError() { mutationError = nil }

    private func mutate(_ mutation: ClipboardMutation) {
        guard mutations.count < 8 else {
            mutationError = "Clipboard changes are still being saved."; return
        }
        let id = UUID()
        history.begin(id, mutation: mutation)
        adopt(history.entries)
        let predecessor = mutationTail
        mutations[id] = Task { [weak self] in
            var succeeded = false
            defer {
                if let self {
                    self.history.finish(id, succeeded: succeeded)
                    self.adopt(self.history.entries)
                }
                self?.mutations[id] = nil
                if self?.mutationTailID == id {
                    self?.mutationTail = nil; self?.mutationTailID = nil
                }
                if self?.mutations.isEmpty == true { self?.reload() }
            }
            await predecessor?.value
            do {
                try Task.checkCancellation()
                guard let client = self?.client else { return }
                _ = try await client.mutate(mutation)
                succeeded = true
                guard !Task.isCancelled else { return }
                self?.mutationError = nil
                self?.reload()
            } catch {
                if !Task.isCancelled {
                    self?.mutationError = error.localizedDescription; self?.reload()
                }
            }
        }
        mutationTail = mutations[id]
        mutationTailID = id
    }

    func activate(_ entry: ClipboardEntry, forcePlainText: Bool = false) {
        activationTask?.cancel()
        activationGeneration += 1
        let activationGeneration = activationGeneration
        let plain =
            forcePlainText
            || SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
        activationTask = Task { [weak self] in
            defer {
                if self?.activationGeneration == activationGeneration { self?.activationTask = nil }
            }
            do {
                guard let client = self?.client else { return }
                let payload = try await client.blob(id: entry.id)
                guard !Task.isCancelled, let self, self.visibility.enabled,
                    self.activationGeneration == activationGeneration
                else { return }
                ClipboardRepository.copyToPasteboard(
                    payload.entry, data: payload.data, asPlainText: plain, pasteboard: .general)
                self.lastChangeCount = NSPasteboard.general.changeCount
                self.mutate(.init(.copied, ids: [entry.id]))
                let defaults = SharedDefaults.store
                guard defaults.bool(forKey: AppStorageKeys.Clipboard.autoPaste),
                    defaults.bool(forKey: AppStorageKeys.Permissions.accessibilityGranted)
                else { return }
                try await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                ClipboardPasteSynth.synthesizeCommandV()
            } catch {
                if !Task.isCancelled { self?.mutationError = error.localizedDescription }
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        captureTask?.cancel()
        activationTask?.cancel()
        mutationTail?.cancel()
        for task in mutations.values { task.cancel() }
    }
}

private struct ClipboardMonitoringState {
    var enabled = true
    var sleeping = false
    var locked = false
    var active: Bool { enabled && !sleeping && !locked }
}
