import Foundation

@MainActor protocol CameraCarrierControlling: AnyObject {
    var currentStatus: CameraCarrierStatus? { get }
    var changed: ((CameraCarrierStatus) -> Void)? { get set }
    func activate() async throws
    func deactivate() async throws
    func prepareMicrophone() async throws
    func prepareDisable(providerVisible: Bool) async throws
}

@MainActor final class CameraCarrierClient: CameraCarrierControlling {
    private let prepare: @MainActor () async throws -> URL
    private let launch: @MainActor (URL) throws -> Process
    private let timeout: Duration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var preparation: Task<URL, Error>?
    private var frames = CameraCarrierFrames()
    private var pending: [UUID: CheckedContinuation<CameraCarrierStatus, Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var admitted: Set<UUID> = []
    private var closing = false
    private(set) var currentStatus: CameraCarrierStatus?
    var changed: ((CameraCarrierStatus) -> Void)?

    init(
        timeout: Duration = .seconds(120), prepare: @escaping @MainActor () async throws -> URL,
        launch: @escaping @MainActor (URL) throws -> Process = CameraCarrierClient.launchProcess
    ) {
        self.timeout = timeout; self.prepare = prepare; self.launch = launch
    }

    func activate() async throws { _ = try await request(.activate) }
    func deactivate() async throws { _ = try await request(.deactivate) }
    func prepareMicrophone() async throws { _ = try await request(.microphonePrepare) }

    func prepareDisable(providerVisible: Bool) async throws {
        guard process != nil || preparation != nil || providerVisible else { return }
        let status = try await request(.deactivate)
        guard !status.ownsProvider, !status.pending, status.phase != "restartRequired" else {
            throw failure("Restart macOS to finish disabling Edith Camera.")
        }
        closing = true
        try input?.close(); input = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while process?.isRunning == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard process?.isRunning != true else {
            closing = false
            throw failure(
                "The camera carrier is still releasing its resources. Try disabling it again.")
        }
        output?.readabilityHandler = nil
        try output?.close(); output = nil
        process = nil; preparation = nil; frames = .init()
    }

    private func request(_ operation: CameraCarrierOperation) async throws -> CameraCarrierStatus {
        let token = UUID()
        guard !closing, admitted.count < 8 else {
            throw failure("Another camera request is still in progress.")
        }
        admitted.insert(token)
        defer { admitted.remove(token) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await connect()
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CameraCarrierStatus, Error>) in
                pending[token] = continuation
                timeouts[token] = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.cancel(
                        token,
                        error: self?.failure(
                            "The camera request timed out. Its cleanup may still be waiting for macOS."
                        ) ?? CancellationError())
                }
                do { try send(.init(token: token, operation: operation)) } catch {
                    finish(token, .failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(token, error: CancellationError()) }
        }
    }

    private func connect() async throws {
        if let process, process.isRunning { return }
        guard !closing else { throw CancellationError() }
        if preparation == nil { preparation = Task { try await prepare() } }
        guard let preparation else { throw CancellationError() }
        let url: URL
        do { url = try await preparation.value } catch { self.preparation = nil; throw error }
        try Task.checkCancellation()
        if let process, process.isRunning { return }
        let child = try launch(url)
        guard let read = child.standardOutput as? Pipe, let write = child.standardInput as? Pipe
        else {
            throw failure("The camera carrier connection is invalid.")
        }
        frames = .init()
        process = child; input = write.fileHandleForWriting; output = read.fileHandleForReading
        output?.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.receive(data)
            }
        }
        child.terminationHandler = { [weak self, weak child] _ in
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.connectionEnded()
            }
        }
        if !child.isRunning { connectionEnded() }
    }

    private func send(_ request: CameraCarrierRequest) throws {
        guard let input, process?.isRunning == true else {
            throw failure("The camera carrier is unavailable.")
        }
        try input.write(contentsOf: CameraCarrierFrames.encode(request))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { connectionEnded(); return }
        do {
            for frame in try frames.append(data) {
                let reply = try JSONDecoder().decode(CameraCarrierReply.self, from: frame)
                guard reply.status.isValid, (reply.error?.utf8.count ?? 0) <= 4096 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                currentStatus = reply.status; changed?(reply.status)
                if let token = reply.token {
                    if let error = reply.error {
                        finish(token, .failure(failure(error)))
                    } else {
                        finish(token, .success(reply.status))
                    }
                }
            }
        } catch { connectionEnded(error: error) }
    }

    private func connectionEnded(error: Error? = nil) {
        output?.readabilityHandler = nil
        for token in Array(pending.keys) {
            finish(
                token,
                .failure(
                    error
                        ?? failure(
                            "The camera carrier connection ended before its request completed.")))
        }
        if currentStatus?.ownsProvider == true {
            let status = CameraCarrierStatus(
                phase: "failed", ownsProvider: true, pending: false,
                message:
                    "The camera provider may still be running. Reopen Edith Camera or restart macOS before disabling it."
            )
            currentStatus = status; changed?(status)
        }
    }

    private func cancel(_ token: UUID, error: Error) {
        guard pending[token] != nil else { return }
        try? send(.init(token: UUID(), operation: .cancel, cancelledToken: token))
        finish(token, .failure(error))
    }

    private func finish(_ token: UUID, _ result: Result<CameraCarrierStatus, Error>) {
        timeouts.removeValue(forKey: token)?.cancel()
        guard let continuation = pending.removeValue(forKey: token) else { return }
        continuation.resume(with: result)
    }

    private static func launchProcess(_ carrier: URL) throws -> Process {
        guard let executable = Bundle(url: carrier)?.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--contained-extension-role"]
        process.standardInput = Pipe(); process.standardOutput = Pipe();
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("DYLD_") || key == "LD_PRELOAD" {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        try process.run()
        return process
    }
    private func failure(_ message: String) -> NSError {
        NSError(
            domain: "EdithCameraCarrier", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
