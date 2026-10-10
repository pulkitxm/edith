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
    private let control: HostCorePipeWriter
    private var frames = HostCoreFrames()
    private var runtime: HostCoreRuntime?
    private var watcher: DispatchSourceProcess?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var stopping = false

    init(parent: ExtensionProcessIdentity) throws {
        self.parent = parent
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        control = try HostCorePipeWriter(descriptor: descriptor)
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
                guard next.operation == .start || next.configuration == nil,
                    next.operation == .command || next.command == nil,
                    next.operation == .cancel || next.cancelling == nil,
                    requests[next.token] == nil, requests.count < 8
                else { throw HostWorkerError.rejected }
                if next.operation == .cancel {
                    guard let runtime else { throw HostWorkerError.rejected }
                    if let token = next.cancelling {
                        requests[token]?.cancel()
                    } else {
                        for (token, task) in requests where token != next.token { task.cancel() }
                        runtime.cancel()
                    }
                }
                if next.operation == .stop {
                    for task in requests.values { task.cancel() }
                    runtime?.cancel()
                }
                requests[next.token] = Task { [self] in
                    defer { requests.removeValue(forKey: next.token) }
                    do {
                        try Task.checkCancellation()
                        guard parent.isAlive, !stopping else { throw HostWorkerError.rejected }
                        if next.operation == .command {
                            guard let runtime, let command = next.command else {
                                throw HostWorkerError.rejected
                            }
                            let result = try await runtime.command(command)
                            try await control.send(
                                HostCoreResponse(token: next.token, commandResult: result))
                        } else {
                            let snapshot = try await execute(next)
                            try await control.send(
                                HostCoreResponse(token: next.token, snapshot: snapshot))
                        }
                        if next.operation == .stop { terminate() }
                    } catch {
                        try? await control.send(
                            HostCoreResponse(
                                token: next.token,
                                failure: error is HostAgentCommandError
                                    ? nil
                                    : "The background service could not complete this action.",
                                cancelled: error is CancellationError,
                                commandFailure: error as? HostAgentCommandError))
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
            #if EDITH_CLI_FIXTURE
            runtime = try HostCoreRuntime(identity: configuration.identity(), environment: { [:] })
            #else
            runtime = try HostCoreRuntime(identity: configuration.identity())
            #endif
            try await runtime?.startCommands()
            return runtime?.snapshot()
        }
        guard request.configuration == nil, let runtime else { throw HostWorkerError.rejected }
        switch request.operation {
        case .status: return runtime.snapshot()
        case .inspect: return try await runtime.inspect()
        case .synchronize: return try await runtime.synchronizeSettings()
        case .restore: return try await runtime.synchronizeSettings(restoreOnly: true)
        case .stop: await runtime.shutdown(); return runtime.snapshot()
        case .cancel: return runtime.snapshot()
        case .start, .command: throw HostWorkerError.rejected
        }
    }

    private func terminate() {
        guard !stopping else { return }
        stopping = true
        for task in requests.values { task.cancel() }
        runtime?.cancel()
        FileHandle.standardInput.readabilityHandler = nil
        watcher?.cancel()
        Task { [self] in
            await runtime?.shutdown()
            await control.shutdown()
            kill(-getpid(), SIGKILL)
            exit(1)
        }
    }
}
