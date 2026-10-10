import AppKit
import Darwin
import EdithHostCore
import EdithExtensionSupport
import Foundation

@MainActor enum HostCoreServiceRole {
    static func run() throws {
        let parent = try HostCoreAdmission.admitParent()
        guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { throw HostWorkerError.rejected }
        try HostCoreRoleApplication(parent: parent).run()
    }
}

@MainActor private final class HostCoreRoleApplication {
    private let parent: ExtensionProcessIdentity
    private let control: HostWorkerControl
    private var frames = HostWorkerFrames()
    private var runtime: HostCoreRuntime?
    private var watcher: DispatchSourceProcess?
    private var request: Task<Void, Never>?
    private var stopping = false

    init(parent: ExtensionProcessIdentity) throws {
        self.parent = parent
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        control = HostWorkerControl(descriptor: descriptor)
    }

    func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let watcher = DispatchSource.makeProcessSource(
            identifier: parent.pid, eventMask: .exit,
            queue: .main)
        watcher.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.terminate() } }
        self.watcher = watcher
        watcher.resume()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        guard parent.isAlive else { terminate(); return }
        NSApplication.shared.run()
    }

    private func receive(_ data: Data) {
        guard !stopping else { return }
        guard !data.isEmpty, parent.isAlive else { terminate(); return }
        do {
            for frame in try frames.append(data) {
                let next = try JSONDecoder().decode(HostCoreRequest.self, from: frame)
                if [.cancel, .status].contains(next.operation) {
                    guard next.configuration == nil, let runtime else {
                        throw HostWorkerError.rejected
                    }
                    if next.operation == .cancel { request?.cancel(); runtime.cancel() }
                    try control.send(
                        HostCoreResponse(token: next.token, snapshot: runtime.snapshot()))
                    continue
                }
                guard request == nil else { throw HostWorkerError.rejected }
                request = Task { [self] in
                    defer { request = nil }
                    do {
                        let snapshot = try await execute(next)
                        try control.send(HostCoreResponse(token: next.token, snapshot: snapshot))
                        if next.operation == .stop { terminate() }
                    } catch {
                        try? control.send(
                            HostCoreResponse(
                                token: next.token,
                                failure: "The background service could not complete this action.",
                                cancelled: error is CancellationError))
                        if next.operation == .start { terminate() }
                    }
                }
            }
        } catch { terminate() }
    }

    private func execute(_ request: HostCoreRequest) async throws -> HostCoreSnapshot? {
        try Task.checkCancellation()
        guard parent.isAlive else { throw HostWorkerError.rejected }
        if request.operation == .start {
            guard runtime == nil, let configuration = request.configuration,
                configuration.identifier == Bundle.main.bundleIdentifier,
                configuration.extensionID == "core", configuration.version == "1",
                !configuration.recoveryOnly
            else { throw HostWorkerError.rejected }
            runtime = try HostCoreRuntime(identity: configuration.identity())
            return runtime?.snapshot()
        }
        guard request.configuration == nil, let runtime else { throw HostWorkerError.rejected }
        switch request.operation {
        case .status: return runtime.snapshot()
        case .inspect: return try await runtime.inspect()
        case .synchronize: return try await runtime.synchronizeSettings()
        case .restore: return try await runtime.synchronizeSettings(restoreOnly: true)
        case .stop: await runtime.shutdown(); return runtime.snapshot()
        case .start, .cancel: throw HostWorkerError.rejected
        }
    }

    private func terminate() {
        guard !stopping else { return }
        stopping = true
        request?.cancel()
        runtime?.cancel()
        FileHandle.standardInput.readabilityHandler = nil
        watcher?.cancel()
        kill(-getpid(), SIGKILL)
        exit(1)
    }
}
