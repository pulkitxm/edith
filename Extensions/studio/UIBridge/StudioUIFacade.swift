import AppKit
import EdithStudio
import SwiftUI
import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class StudioUIFacade {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let invoke: Invoke
    private let settingsOnly: Bool
    private let presentationID: UUID?
    private let invalidate: @MainActor () -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let owned = StudioTaskOwner()
    private let cleanupOwned = StudioTaskOwner()
    private nonisolated let callbacks = StudioTaskOwner()
    var activeWork: Set<UUID> = []
    var retainedWork: Set<UUID> = []
    let exporter = VideoExporter()
    private var activeRequests = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cleanupQueue: [(String, Data)] = []
    private var cleanupTask: Task<Void, Never>?
    private var invalidationDeadline: Task<Void, Never>?
    private var invalidationTask: Task<Void, Never>?
    private var invalidated = false
    private var commandsSuspended = false
    private var versions: [String: UUID] = [:]
    var onState: (@MainActor (StudioUIState) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var isStopped = false
    private(set) var state: StudioUIState?
    private(set) var failure: String?

    init(client: ExtensionEngineClient, settingsOnly: Bool = false) {
        self.settingsOnly = settingsOnly
        presentationID = client.presentationID
        invoke = { operation, payload in try await client.invoke(operation, payload: payload) }
        invalidate = { client.invalidate() }
        configureExportControls()
    }

    init(
        settingsOnly: Bool = false, invoke: @escaping Invoke,
        invalidate: @escaping @MainActor () -> Void = {}
    ) {
        self.settingsOnly = settingsOnly
        presentationID = nil
        self.invoke = invoke
        self.invalidate = invalidate
        configureExportControls()
    }

    private func configureExportControls() {
        exporter.remoteCancel = { [weak self] token in
            self?.cleanup("studio.ui.work.cancel", object: ["token": token.uuidString])
            self?.cleanup("studio.ui.work.end", object: ["token": token.uuidString])
        }
        exporter.remoteClear = { [weak self] token in
            self?.cleanup(
                "studio.ui.video.export.clear",
                object: ["id": UUID().uuidString, "token": token.uuidString])
        }
    }

    func refresh() {
        guard !settingsOnly || versions["destination"] == nil else { return }
        submit("state") { [weak self] in
            guard let self else { return nil }
            let value: StudioUIState = try await self.read(
                self.settingsOnly ? "studio.ui.settings" : "studio.ui.state")
            return {
                self.state = value; self.failure = nil; self.exporter.applyRemote(value.export);
                self.onState?(value)
            }
        }
    }

    func observe() {
        submit("observation") { [weak self] in
            while let self, !self.isStopped {
                if self.versions["state"] == nil { self.refresh() }
                try await Task.sleep(for: .seconds(1))
            }
            return nil
        }
    }

    func action(
        _ operation: String, object: [String: Any] = [:],
        then: @escaping @MainActor () -> Void = {}
    ) {
        submit(UUID().uuidString) { [weak self] in
            guard let self else { return nil }
            let _: StudioUIState = try await self.read(operation, object: object)
            return {
                then(); self.refresh()
            }
        }
    }

    func setDestination(mode: String, folder: String) {
        guard settingsOnly else {
            action("studio.ui.preferences", object: ["mode": mode, "folder": folder])
            return
        }
        if let previous = versions.removeValue(forKey: "state") {
            tasks.removeValue(forKey: previous)?.cancel()
        }
        submit("destination") { [weak self] in
            guard let self else { return nil }
            let value: StudioUIState = try await self.read(
                "studio.ui.settings.preferences", object: ["mode": mode, "folder": folder])
            return {
                self.state = value; self.failure = nil; self.onState?(value)
            }
        }
    }

    func openSettingsStudio() {
        submit("openStudio") { [weak self] in
            guard let self else { return nil }
            let _: [String: String] = try await self.read(
                "studio.ui.settings.open",
                object: ["presentationID": self.presentationID?.uuidString ?? ""])
            return nil
        }
    }

    func run(_ job: StudioJob, onFinish: @escaping @MainActor (StudioJob) -> Void) {
        submit(job.id.uuidString) { [weak self, weak job] in
            guard let self, let job else { return nil }
            let settings = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(job.settings))
            var value: StudioUIJobState = try await self.read(
                "studio.ui.job.start",
                object: [
                    "id": job.id.uuidString, "toolID": job.tool.id,
                    "paths": job.inputs.map(\.path), "settings": settings,
                ])
            while !self.isStopped, !Task.isCancelled {
                job.apply(value)
                if value.phase != "running" {
                    if value.phase == "finished" { onFinish(job) }
                    return nil
                }
                try await Task.sleep(for: .milliseconds(80))
                value = try await self.read("studio.ui.job.read", object: ["id": job.id.uuidString])
            }
            return nil
        }
    }

    func cancel(_ job: StudioJob) {
        if let task = versions[job.id.uuidString] { tasks[task]?.cancel() }
        action("studio.ui.job.cancel", object: ["id": job.id.uuidString])
    }

    func add(_ urls: [URL], then: @escaping @MainActor () -> Void = {}) {
        mutate("studio.library.add", object: ["paths": urls.map(\.path)], then: then)
    }

    func remove(_ urls: Set<URL>) {
        mutate("studio.library.remove", object: ["paths": urls.map(\.path)])
    }

    func clearMissing() {
        mutate("studio.ui.clearMissing")
    }

    func facts(_ url: URL) async throws -> StudioFileFacts {
        let value: StudioUIFileFacts = try await read("studio.ui.facts", object: ["path": url.path])
        return value.value
    }

    func read<Value: Decodable>(_ operation: String, object: [String: Any] = [:]) async throws
        -> Value
    {
        guard !isStopped, !commandsSuspended else { throw ExtensionEngineError.unavailable }
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard payload.count <= StudioCommands.maximumRequestBytes else {
            throw ExtensionEngineError.rejected
        }
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let data = try await invoke(operation, payload)
        try Task.checkCancellation()
        guard !isStopped, !commandsSuspended, data.count <= ExtensionEngineWire.maximumPayloadBytes
        else {
            throw ExtensionEngineError.unavailable
        }
        if let failure = try? JSONDecoder().decode(StudioUIFailure.self, from: data) {
            guard !failure.studioFailure.isEmpty, failure.studioFailure.utf8.count <= 16_384 else {
                throw ExtensionEngineError.rejected
            }
            throw StudioUIOperationFailure(message: failure.studioFailure)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if let token = exporter.detach() {
            queueCleanup("studio.ui.work.detach", object: ["token": token.uuidString])
        }
        owned.shutdown()
        callbacks.shutdown()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        versions.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: CancellationError()) }
        waiting.removeAll()
        for token in activeWork {
            if retainedWork.contains(token) {
                queueCleanup("studio.ui.work.detach", object: ["token": token.uuidString])
            } else {
                queueCleanup("studio.ui.work.cancel", object: ["token": token.uuidString])
                queueCleanup("studio.ui.work.end", object: ["token": token.uuidString])
            }
        }
        if let cleanupTask {
            invalidationTask = cleanupOwned.start { [weak self] in
                await cleanupTask.value
                self?.finishInvalidation()
            }
            invalidationDeadline = cleanupOwned.start { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.cleanupTask?.cancel()
                self?.finishInvalidation()
            }
        } else {
            finishInvalidation()
        }
    }

    func suspendCommands() {
        guard !commandsSuspended else { return }
        commandsSuspended = true
        owned.shutdown()
        callbacks.shutdown()
        exporter.suspendCommands()
        cleanupTask?.cancel()
        for (_, continuation) in waiting { continuation.resume(throwing: CancellationError()) }
        waiting.removeAll()
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        await exporter.suspendCommandsAndWait()
        await owned.shutdownAndWait()
        await callbacks.shutdownAndWait()
        await cleanupOwned.waitForPendingWork()
    }

    func stopAndWait() async {
        stop()
        await exporter.waitForPendingWork()
        await owned.shutdownAndWait()
        await callbacks.shutdownAndWait()
        await cleanupOwned.waitForPendingWork()
        await cleanupOwned.shutdownAndWait()
    }

    func cleanup(_ operation: String, object: [String: Any]) {
        guard !commandsSuspended else { return }
        queueCleanup(operation, object: object)
    }

    private func queueCleanup(_ operation: String, object: [String: Any]) {
        guard !invalidated, cleanupQueue.count < 128,
            let payload = try? JSONSerialization.data(
                withJSONObject: object, options: [.withoutEscapingSlashes]),
            payload.count <= StudioCommands.maximumRequestBytes
        else { return }
        cleanupQueue.append((operation, payload))
        guard cleanupTask == nil else { return }
        cleanupTask = cleanupOwned.start { [weak self] in
            guard let self else { return }
            defer { self.cleanupTask = nil }
            while !self.cleanupQueue.isEmpty, !Task.isCancelled, !self.invalidated {
                let (operation, payload) = self.cleanupQueue.removeFirst()
                _ = try? await self.invoke(operation, payload)
            }
        }
    }

    private func finishInvalidation() {
        guard !invalidated else { return }
        invalidated = true
        cleanupQueue.removeAll()
        invalidationDeadline?.cancel(); invalidationTask?.cancel()
        invalidationDeadline = nil; invalidationTask = nil
        invalidate()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard !isStopped, !commandsSuspended else { throw ExtensionEngineError.unavailable }
        if activeRequests < 6 { activeRequests += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
                if Task.isCancelled { cancelWaiting(id) }
            }
        } onCancel: {
            callbacks.enqueue { [weak self] in self?.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiting.isEmpty, !isStopped {
            waiting.removeFirst().1.resume()
        } else {
            activeRequests -= 1
        }
    }

    private func mutate(
        _ operation: String, object: [String: Any] = [:], then: @escaping @MainActor () -> Void = {}
    ) {
        submit(UUID().uuidString) { [weak self] in
            guard let self else { return nil }
            let _: [StudioMediaItem] = try await self.read(operation, object: object)
            return {
                then(); self.refresh()
            }
        }
    }

    private func submit(
        _ key: String, work: @escaping @MainActor () async throws -> (@MainActor () -> Void)?
    ) {
        guard !isStopped, !commandsSuspended else { return }
        let version = UUID()
        if let previous = versions[key] { tasks[previous]?.cancel(); tasks[previous] = nil }
        versions[key] = version
        tasks[version] = owned.start { [weak self] in
            defer {
                self?.tasks[version] = nil
                if self?.versions[key] == version { self?.versions[key] = nil }
            }
            do {
                let apply = try await work()
                guard let self, !self.isStopped, !Task.isCancelled, self.versions[key] == version
                else { return }
                apply?()
            } catch {
                guard let self, !self.isStopped, !Task.isCancelled, self.versions[key] == version
                else { return }
                self.failure = error.localizedDescription
                self.onFailure?(error.localizedDescription)
            }
        }
    }
}

private struct StudioFacadeKey: EnvironmentKey {
    static let defaultValue: StudioUIFacade? = nil
}

extension EnvironmentValues {
    var studioFacade: StudioUIFacade? {
        get { self[StudioFacadeKey.self] }
        set { self[StudioFacadeKey.self] = newValue }
    }
}
