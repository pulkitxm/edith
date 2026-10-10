import Foundation

@MainActor
final class CameraCarrierSession {
    private let controller: CameraSystemExtensionController
    private let microphoneOnly: Bool
    private let send: (Data) throws -> Void
    private let prepareMicrophone: @MainActor () async throws -> Void
    private let prepareDisableResources: @MainActor () async throws -> Void
    private let releaseResources: @MainActor () async throws -> Void
    private let exited: () -> Void
    private var frames = CameraCarrierFrames()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var disconnectTask: Task<Void, Never>?
    private(set) var disconnected = false
    private(set) var released = false
    private var cleaning = false
    private var draining = false

    init(
        controller: CameraSystemExtensionController, send: @escaping (Data) throws -> Void,
        microphoneOnly: Bool = false,
        prepareMicrophone: @escaping @MainActor () async throws -> Void,
        prepareDisableResources: @escaping @MainActor () async throws -> Void = {},
        releaseResources: @escaping @MainActor () async throws -> Void, exited: @escaping () -> Void
    ) {
        self.microphoneOnly = microphoneOnly
        self.controller = controller
        self.send = send
        self.prepareMicrophone = prepareMicrophone
        self.prepareDisableResources = prepareDisableResources
        self.releaseResources = releaseResources
        self.exited = exited
        controller.changed = { [weak self] _ in self?.publish(token: nil) }
    }

    func receive(_ bytes: Data) {
        guard !disconnected else { return }
        guard !bytes.isEmpty else { disconnect(); return }
        do {
            for frame in try frames.append(bytes) {
                let request = try JSONDecoder().decode(CameraCarrierRequest.self, from: frame)
                guard requests[request.token] == nil,
                    (request.operation == .status || request.operation == .cancel
                        || requests.count < 8),
                    (request.operation == .cancel) == (request.cancelledToken != nil)
                else { throw CocoaError(.fileReadCorruptFile) }
                if microphoneOnly
                    && (request.operation == .activate || request.operation == .deactivate)
                {
                    publish(
                        token: request.token,
                        error:
                            "Video uses OBS Virtual Camera. No camera provider is installed by Edith."
                    )
                    continue
                }
                switch request.operation {
                case .cancel:
                    if let token = request.cancelledToken { requests[token]?.cancel() }
                    publish(token: request.token)
                case .status: publish(token: request.token)
                case .activate, .deactivate, .prepareDisable, .microphonePrepare:
                    if draining
                        && (request.operation == .activate
                            || request.operation == .microphonePrepare)
                    {
                        publish(token: request.token, error: "Camera is releasing its resources.")
                        continue
                    }
                    let preceding =
                        request.operation == .prepareDisable ? Array(requests.values) : []
                    if request.operation == .prepareDisable {
                        draining = true
                        for task in preceding { task.cancel() }
                    }
                    requests[request.token] = Task { [weak self] in
                        guard let self else { return }
                        defer { requests.removeValue(forKey: request.token) }
                        do {
                            switch request.operation {
                            case .activate: try await controller.activate()
                            case .deactivate: try await controller.deactivate()
                            case .prepareDisable:
                                for task in preceding { await task.value }
                                try await deactivateOwnedResources()
                            case .microphonePrepare: try await prepareMicrophone()
                            default: throw CocoaError(.fileReadCorruptFile)
                            }
                            try Task.checkCancellation()
                            publish(token: request.token)
                        } catch { publish(token: request.token, error: error.localizedDescription) }
                    }
                }
            }
        } catch { disconnect() }
    }

    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        draining = true
        let pending = Array(requests.values)
        for request in pending { request.cancel() }
        cleaning = true
        disconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { cleaning = false }
            do {
                for request in pending { await request.value }
                try await deactivateOwnedResources()
                guard !controller.ownsProvider, !controller.pendingRequest else { return }
                try await releaseResources()
                released = true
                exited()
            } catch {}
        }
    }

    func retryDisconnectedCleanup() {
        guard disconnected, !released, !cleaning, controller.phase != .restartRequired else {
            return
        }
        cleaning = true
        disconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { cleaning = false }
            do {
                try await deactivateOwnedResources()
                guard !controller.ownsProvider, !controller.pendingRequest else { return }
                try await releaseResources()
                released = true
                exited()
            } catch {}
        }
    }

    private func deactivateOwnedResources() async throws {
        try await controller.deactivate()
        do { try await prepareDisableResources() } catch let error as CameraCarrierRestartRequired {
            controller.retainUntilRestart(error.message)
            throw error
        }
    }

    private func publish(token: UUID?, error: String? = nil) {
        guard !disconnected else { return }
        do {
            try send(
                CameraCarrierFrames.encode(
                    CameraCarrierReply(
                        token: token, status: .init(controller),
                        error: error.map { String($0.prefix(1024)) })))
        } catch { disconnect() }
    }
}
