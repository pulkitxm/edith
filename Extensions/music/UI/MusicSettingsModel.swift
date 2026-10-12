import EdithExtensionSupport
import Foundation
import Observation
import SwiftUI

struct EmbeddedMusicUISettings: Codable, Sendable {
    var version: String
    var preferences: EmbeddedMusicUIPreferences

    func validate(expectedVersion: String?) throws {
        guard !version.isEmpty, version.utf8.count <= 128, !version.utf8.contains(0),
            expectedVersion == nil || version == expectedVersion,
            preferences.fadeLength.isFinite,
            EmbeddedMusicFade.secondsRange.contains(preferences.fadeLength)
        else { throw ExtensionPeerError.invalidRequest }
    }
}

@MainActor @Observable final class EmbeddedMusicSettingsModel {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let expectedVersion: String?
    @ObservationIgnored private var invoke: Invoke?
    @ObservationIgnored private let applyReadback: (EmbeddedMusicUIPreferences) -> Void
    @ObservationIgnored private let didSave: () -> Void
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycle: UInt64 = 0
    private var revision: UInt64 = 0
    private var pending: [EmbeddedMusicUIActionKind: Double] = [:]
    private var order: [EmbeddedMusicUIActionKind] = []
    private var requested: [EmbeddedMusicUIActionKind: Double] = [:]
    private var activeWrite: (kind: EmbeddedMusicUIActionKind, value: Double)?
    private(set) var preferences = EmbeddedMusicUIPreferences()
    private(set) var loaded = false
    private(set) var closed = false
    private(set) var error: String?

    init(
        expectedVersion: String? = nil,
        applyReadback: ((EmbeddedMusicUIPreferences) -> Void)? = nil,
        didSave: (() -> Void)? = nil,
        invoke: @escaping Invoke
    ) {
        self.expectedVersion = expectedVersion; self.invoke = invoke
        self.applyReadback = applyReadback ?? { EmbeddedMusicRemote.shared.applyPreferences($0) }
        self.didSave = didSave ?? { EmbeddedMusicRemote.shared.rescan(force: true) }
    }

    func refresh() async {
        guard !closed, writeTask == nil, let invoke else { return }
        revision &+= 1; readTask?.cancel()
        let token = lifecycle
        let currentRevision = revision
        let task = ownedTask { [weak self] in
            guard let self else { return }
            do {
                let value = try await read(invoke)
                guard lifecycle == token, revision == currentRevision, !closed else { return }
                apply(value)
            } catch {
                guard !Task.isCancelled, lifecycle == token, revision == currentRevision, !closed
                else { return }
                self.error = error.localizedDescription
            }
        }
        readTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if lifecycle == token, revision == currentRevision { readTask = nil }
    }

    func boolean(
        _ kind: EmbeddedMusicUIActionKind, _ path: KeyPath<EmbeddedMusicUIPreferences, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { self.requested[kind].map { $0 == 1 } ?? self.preferences[keyPath: path] },
            set: { self.set(kind, value: $0 ? 1 : 0) })
    }

    var fadeLength: Binding<Double> {
        Binding(
            get: { self.requested[.fadeLength] ?? self.preferences.fadeLength },
            set: {
                guard $0.isFinite else { return }
                self.set(.fadeLength, value: min(max($0, 0.5), 8))
            })
    }

    func set(_ kind: EmbeddedMusicUIActionKind, value: Double) {
        guard loaded, !closed, invoke != nil, value.isFinite else { return }
        switch kind {
        case .barCollapsed, .barAutoHide, .crossfade:
            guard value == 0 || value == 1 else { return }
        case .fadeLength:
            guard EmbeddedMusicFade.secondsRange.contains(value) else { return }
        default: return
        }
        revision &+= 1; readTask?.cancel(); readTask = nil
        if pending[kind] == nil { order.append(kind) }
        pending[kind] = value; requested[kind] = value
        guard writeTask == nil else { return }
        let token = lifecycle
        writeTask = ownedTask { [weak self] in
            guard let self else { return }; await self.write(token: token)
        }
    }

    func suspendCommands() {
        lifecycle &+= 1; revision &+= 1; closed = true
        for task in ownedTasks.values { task.cancel() }
        readTask = nil; writeTask = nil
    }

    func prepareToClose() async throws {
        while let writeTask {
            await writeTask.value
            try Task.checkCancellation()
        }
        guard pending.isEmpty, requested.isEmpty, activeWrite == nil else {
            throw ExtensionPeerError.rejected(error ?? "Music settings still have pending changes.")
        }
        await suspendCommandsAndWait()
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        let tasks = Array(ownedTasks.values)
        for task in tasks { await task.value }
    }

    func stop() {
        suspendCommands()
        invoke = nil
        pending = [:]; requested = [:]; order = []; activeWrite = nil
        preferences = EmbeddedMusicUIPreferences(); loaded = false; error = nil
    }

    func stopAndWait() async {
        stop()
        let tasks = Array(ownedTasks.values)
        for task in tasks { await task.value }
    }

    private func ownedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.ownedTasks[id] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
        ownedTasks[id] = task
        return task
    }

    private func write(token: UInt64) async {
        defer { if lifecycle == token { writeTask = nil } }
        guard let invoke else { return }
        do {
            while !order.isEmpty {
                try Task.checkCancellation()
                guard lifecycle == token, !closed else { return }
                let kind = order.removeFirst()
                guard let value = pending.removeValue(forKey: kind) else { continue }
                activeWrite = (kind, value)
                _ = try await invoke(
                    "music.ui.action",
                    JSONEncoder().encode(EmbeddedMusicUIAction(kind: kind, value: value)))
                try Task.checkCancellation()
                guard lifecycle == token, !closed else { return }
                let currentRevision = revision
                let settings = try await read(invoke)
                guard lifecycle == token, !closed else { return }
                if revision == currentRevision {
                    apply(settings)
                    didSave()
                    if pending[kind] == nil { requested[kind] = nil }
                }
                activeWrite = nil
            }
            requested = [:]
        } catch {
            guard !Task.isCancelled, lifecycle == token, !closed else { return }
            if let activeWrite, pending[activeWrite.kind] == nil {
                pending[activeWrite.kind] = activeWrite.value
                order.insert(activeWrite.kind, at: 0)
            }
            activeWrite = nil
            self.error = error.localizedDescription
        }
    }

    private func read(_ invoke: Invoke) async throws -> EmbeddedMusicUISettings {
        let data = try await invoke("music.ui.settings", Data("{}".utf8))
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 4096 else { throw ExtensionPeerError.invalidRequest }
        let value = try JSONDecoder().decode(EmbeddedMusicUISettings.self, from: data)
        try value.validate(expectedVersion: expectedVersion)
        return value
    }

    private func apply(_ value: EmbeddedMusicUISettings) {
        preferences = value.preferences; loaded = true; error = nil
        applyReadback(value.preferences)
    }
}
