import AppKit
import Darwin
import ExtensionMarketplace
import Foundation

@MainActor
final class HostRemoteCarrierCheckIn {
    private static var pending: [String: HostRemoteCarrierCheckIn] = [:]
    private let id: String
    private let key: String
    private let executable: URL
    private let lease: PackageFileLock
    private var application: NSRunningApplication?
    private var peer: HostRemoteProcessIdentity?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var cancelled = false
    private var completed = false
    private var result: Result<Void, any Error>?

    private init(id: String, key: String, executable: URL, lease: PackageFileLock) {
        self.id = id
        self.key = key
        self.executable = executable
        self.lease = lease
    }

    static func register(configuration: HostRemoteConfiguration, store: ExtensionPackageStore)
        async throws
    {
        try configuration.validate(
            hostIdentifier: configuration.worker.identifier,
            extensionID: configuration.package.id, version: configuration.package.version)
        try Task.checkCancellation()
        let key = configuration.worker.identifier + ":" + configuration.package.id
        try await stop(extensionID: configuration.package.id)
        let lease = try store.lease(configuration.package)
        let payload = store.directory(for: configuration.package).appendingPathComponent(
            configuration.package.id)
        let development = try configuration.worker.identity().development
        let team = ExtensionCodeSignature.teamIdentifier()
        let carrier = try await Task.detached {
            let carrier = try ExtensionUICarrier(
                payload: payload, package: configuration.package,
                expectedHostIdentifier: configuration.worker.identifier)
            if development {
                try carrier.verifyDevelopment()
            } else {
                guard let team else { throw MarketplaceError.invalidSignature }
                try carrier.verify(teamIdentifier: team)
            }
            return carrier
        }.value
        try Task.checkCancellation()
        guard
            try HostRemoteKernelIdentity.read(getpid()).executable.path
                == carrier.hostExecutablePath,
            pending[key] == nil, pending.count < 64
        else { throw HostWorkerError.rejected }
        let checkIn = HostRemoteCarrierCheckIn(
            id: configuration.package.id, key: key,
            executable: carrier.application.appendingPathComponent("Contents/MacOS/Edith"),
            lease: lease)
        pending[checkIn.key] = checkIn
        let launch = NSWorkspace.OpenConfiguration()
        launch.arguments = ["--extension-ui-carrier"]
        launch.activates = false
        launch.hides = true
        launch.createsNewApplicationInstance = true
        launch.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: carrier.application, configuration: launch) {
            application, error in
            Task { @MainActor in checkIn.didLaunch(application, error: error) }
        }
        try await checkIn.wait()
    }

    static func stop(extensionID: String) async throws {
        for operation in pending.values.filter({ $0.id == extensionID }) {
            operation.cancel()
            operation.beginCleanup()
            let until = ContinuousClock.now + .seconds(8)
            while pending[operation.key] === operation {
                guard ContinuousClock.now < until else { throw HostWorkerError.stillRunning }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    static var extensionIDs: Set<String> { Set(pending.values.map(\.id)) }

    private func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.cancel(error: HostWorkerError.timedOut)
                }
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func didLaunch(_ application: NSRunningApplication?, error: (any Error)?) {
        guard !completed else { return }
        if let error {
            finish(.failure(error))
            return
        }
        guard let application else {
            finish(.failure(HostWorkerError.exited))
            return
        }
        self.application = application
        beginCleanup()
    }

    private func beginCleanup() {
        guard cleanup == nil, let application else { return }
        cleanup = Task { [self] in
            defer { cleanup = nil }
            do {
                guard
                    application.bundleURL?.resolvingSymlinksInPath()
                        == executable.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().resolvingSymlinksInPath()
                else { throw HostWorkerError.rejected }
                if application.isTerminated {
                    finish(cancelled ? .failure(CancellationError()) : .success(()))
                    return
                }
                let actual = try HostRemoteProcessIdentity.verify(
                    application.processIdentifier, executable: executable)
                peer = actual
                if cancelled { terminate() }
                let until = ContinuousClock.now + .seconds(5)
                while actual.isRunning {
                    if ContinuousClock.now >= until {
                        terminate()
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let killedUntil = ContinuousClock.now + .seconds(2)
                while actual.isRunning {
                    guard ContinuousClock.now < killedUntil else {
                        throw HostWorkerError.stillRunning
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                finish(cancelled ? .failure(CancellationError()) : .success(()))
            } catch {
                resolve(.failure(error))
                let until = ContinuousClock.now + .seconds(2)
                while !application.isTerminated, peer?.isRunning != false,
                    ContinuousClock.now < until
                {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if peer?.isRunning == false || application.isTerminated { finish(.failure(error)) }
            }
        }
    }

    private func cancel(error: any Error = CancellationError()) {
        cancelled = true
        resolve(.failure(error))
        terminate()
    }

    private func terminate() {
        guard let peer, peer.isRunning else { return }
        _ = kill(peer.pid, SIGKILL)
    }

    private func resolve(_ value: Result<Void, any Error>) {
        guard result == nil else { return }
        result = value
        deadline?.cancel()
        deadline = nil
        continuation?.resume(with: value)
        continuation = nil
    }

    private func finish(_ value: Result<Void, any Error>) {
        guard !completed else { return }
        completed = true
        resolve(value)
        lease.close()
        if Self.pending[key] === self { Self.pending[key] = nil }
    }
}
