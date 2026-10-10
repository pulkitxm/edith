import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistoryModel {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var error: String?
    private(set) var copiedID: String?
    var isSaving: Bool { !mutations.isEmpty }
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var refreshTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var mutations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private nonisolated(unsafe) var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var mutationTailID: UUID?
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var generation = 0
    private var started = false
    let client: ClipboardClient
    private let observesNotifications: Bool
    private let copyRecord: (@MainActor (String) async throws -> Void)?
    @ObservationIgnored private var history = ClipboardHistoryProjection()

    init(
        client: ClipboardClient, observesNotifications: Bool = true,
        copyRecord: (@MainActor (String) async throws -> Void)? = nil
    ) {
        self.client = client
        self.observesNotifications = observesNotifications
        self.copyRecord = copyRecord
    }

    func start() {
        guard !started else { return }
        started = true
        generation += 1
        if observesNotifications {
            observer = IPC.observe(IPC.Name.clipboardChanged) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        }
        reload()
    }

    func stop(discardContent: Bool = false) {
        if discardContent {
            entries.removeAll(); history = ClipboardHistoryProjection(); error = nil; copiedID = nil
        }
        started = false
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        for task in mutations.values { task.cancel() }
        mutations.removeAll()
        mutationTail?.cancel()
        mutationTail = nil
        mutationTailID = nil
        if let observer { IPC.stopObserving(observer) }
        observer = nil
    }

    func shutdown() async {
        let tasks = [refreshTask, mutationTail].compactMap { $0 } + Array(mutations.values)
        stop()
        for task in tasks { await task.value }
        entries.removeAll(); history = ClipboardHistoryProjection(); error = nil; copiedID = nil
    }

    func reload() {
        guard mutations.isEmpty else { pendingRefresh = true; return }
        guard refreshTask == nil else { pendingRefresh = true; return }
        let generation = generation
        refreshTask = Task { [weak self] in
            defer { if self?.generation == generation { self?.refreshTask = nil } }
            repeat {
                self?.pendingRefresh = false
                do {
                    guard let client = self?.client else { return }
                    let entries = try await client.entries()
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.history.replace(entries)
                    if let self, self.entries != self.history.entries {
                        self.entries = self.history.entries
                    }
                } catch {
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.error = error.localizedDescription
                }
            } while self?.pendingRefresh == true && !Task.isCancelled
        }
    }

    func mutate(_ mutation: ClipboardMutation) {
        guard mutations.count < 8 else {
            error = "Clipboard changes are still being saved."; return
        }
        run(mutation: mutation) { client in _ = try await client.mutate(mutation) }
    }

    func copy(_ entry: ClipboardEntry) {
        if let copyRecord {
            run { [weak self] _ in
                try await copyRecord(entry.id)
                try Task.checkCancellation()
                self?.copiedID = entry.id
            }
            return
        }
        let plain = SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.pastePlainText)
        run { [weak self] client in
            let payload = try await client.copy(id: entry.id, plainTextOnly: plain)
            try Task.checkCancellation()
            ClipboardRepository.copyToPasteboard(
                payload, pasteboard: .general)
            self?.copiedID = entry.id
            _ = try await client.mutate(.init(.copied, ids: [entry.id]))
        }
    }

    private func run(
        mutation: ClipboardMutation? = nil,
        _ action: @escaping @MainActor (ClipboardClient) async throws -> Void
    ) {
        guard mutations.count < 8 else {
            error = "Clipboard changes are still being saved."; return
        }
        let id = UUID()
        if let mutation { history.begin(id, mutation: mutation); entries = history.entries }
        let generation = generation
        let predecessor = mutationTail
        mutations[id] = Task { [weak self] in
            var succeeded = false
            defer {
                if let self, self.generation == generation {
                    self.history.finish(id, succeeded: succeeded)
                    self.entries = self.history.entries
                }
                self?.mutations[id] = nil
                if self?.mutationTailID == id {
                    self?.mutationTail = nil; self?.mutationTailID = nil
                }
                if self?.generation == generation, self?.mutations.isEmpty == true {
                    self?.reload()
                }
            }
            await predecessor?.value
            do {
                try Task.checkCancellation()
                guard let client = self?.client else { return }
                try await action(client)
                succeeded = true
                guard !Task.isCancelled, self?.generation == generation else { return }
                self?.error = nil
                self?.reload()
            } catch {
                if !Task.isCancelled, self?.generation == generation {
                    self?.error = error.localizedDescription; self?.reload()
                }
            }
        }
        mutationTail = mutations[id]
        mutationTailID = id
    }

    deinit {
        refreshTask?.cancel()
        mutationTail?.cancel()
        for task in mutations.values { task.cancel() }
    }
}
