import Foundation

public struct HostFolderChoiceOrigin: Equatable, Sendable {
    public let extensionID: String
    public let version: String
    public let presentationID: UUID
    public let enginePID: Int32
    public let engineGeneration: String
    public let rendererPID: Int32
    public let rendererGeneration: String
    public let windowRegistration: UUID

    public init(
        extensionID: String, version: String, presentationID: UUID,
        enginePID: Int32, engineGeneration: String, rendererPID: Int32,
        rendererGeneration: String, windowRegistration: UUID
    ) {
        self.extensionID = extensionID; self.version = version; self.presentationID = presentationID
        self.enginePID = enginePID; self.engineGeneration = engineGeneration
        self.rendererPID = rendererPID; self.rendererGeneration = rendererGeneration
        self.windowRegistration = windowRegistration
    }

    public func validate(_ request: HostWorkerNavigationRequest) throws {
        guard extensionID == "herdr", extensionID == request.extensionID,
            version == request.version,
            presentationID == request.presentationID, request.folderChoice == true,
            request.location == "settings", request.section == "agentActivity",
            request.relativePath == nil, request.machinesWindow == nil, request.herdrWindow == nil,
            enginePID > 1, rendererPID > 1, !engineGeneration.isEmpty, !rendererGeneration.isEmpty
        else { throw HostWorkerError.rejected }
    }
}

@MainActor
public final class HostFolderChoiceCoordinator {
    private let origin: @MainActor (HostWorkerNavigationRequest) throws -> HostFolderChoiceOrigin
    private let select:
        @MainActor (HostWorkerNavigationRequest) async throws -> HostFolderChoiceResult
    private let cancelSelection: @MainActor (UUID) -> Void
    private var pending: [UUID: Task<HostFolderChoiceResult, any Error>] = [:]
    private var stopped = false

    public init(
        origin: @escaping @MainActor (HostWorkerNavigationRequest) throws -> HostFolderChoiceOrigin,
        select:
            @escaping @MainActor (HostWorkerNavigationRequest) async throws ->
            HostFolderChoiceResult,
        cancelSelection: @escaping @MainActor (UUID) -> Void
    ) {
        self.origin = origin; self.select = select; self.cancelSelection = cancelSelection
    }

    public var pendingCount: Int { pending.count }

    public func choose(_ request: HostWorkerNavigationRequest) async throws
        -> HostFolderChoiceResult
    {
        try Task.checkCancellation()
        guard !stopped, pending.isEmpty else { throw HostWorkerError.rejected }
        let admitted = try origin(request)
        try admitted.validate(request)
        let selection = Task { try await select(request) }
        pending[request.token] = selection
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let self, !self.stopped, try self.origin(request) == admitted else {
                        throw HostWorkerError.rejected
                    }
                } catch {
                    if !Task.isCancelled { self?.cancel(request.token) }
                    return
                }
            }
        }
        defer { monitor.cancel(); pending.removeValue(forKey: request.token) }
        return try await withTaskCancellationHandler {
            let result = try await selection.value
            try Task.checkCancellation()
            guard !stopped, pending[request.token] != nil, try origin(request) == admitted else {
                throw HostWorkerError.rejected
            }
            try result.validate()
            return result
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request.token) }
        }
    }

    public func cancel(_ token: UUID) {
        guard let task = pending.removeValue(forKey: token) else { return }
        task.cancel()
        cancelSelection(token)
    }

    public func stop() {
        stopped = true
        for token in Array(pending.keys) { cancel(token) }
    }
}
