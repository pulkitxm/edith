import EdithCameraSupport
import EdithCore
import Foundation

public enum VirtualCameraIPC {
    public static let requestKey = "request"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let snapshotKey = "snapshot"
    public static let okKey = "ok"
    public static let errorKey = "error"
    public static let originKey = "origin"
    public static let stateKey = "state"
}

public enum VirtualCameraOperation: String, CaseIterable, Equatable, Sendable {
    case status
    case on
    case off
    case sources
    case source
    case zoom
    case frame
    case reset
    case look
    case background
    case pause
    case resume
    case sceneList
    case sceneApply
    case sceneSave
    case sceneNext
    case scenePrevious

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status: descriptor(["status"], "Show the virtual camera state.", .read)
        case .on: descriptor(["on"], "Turn the virtual camera on.", .write)
        case .off: descriptor(["off"], "Turn the virtual camera off.", .write)
        case .sources: descriptor(["sources"], "List the cameras Edith can use.", .read)
        case .source: descriptor(["source"], "Choose the camera Edith frames.", .write)
        case .zoom: descriptor(["zoom"], "Set the zoom level.", .write)
        case .frame: descriptor(["frame"], "Set zoom, position, tilt and auto-framing.", .write)
        case .reset: descriptor(["reset"], "Reset the framing to the full picture.", .write)
        case .look: descriptor(["look"], "Apply a color look.", .write)
        case .background: descriptor(["background"], "Blur or replace the background.", .write)
        case .pause:
            descriptor(["pause"], "Hide the camera behind a card, blank or frozen frame.", .write)
        case .resume: descriptor(["resume"], "Show the live camera again.", .write)
        case .sceneList: descriptor(["scene", "list"], "List saved scenes.", .read)
        case .sceneApply: descriptor(["scene", "apply"], "Switch to a saved scene.", .write)
        case .sceneSave: descriptor(["scene", "save"], "Save the current look as a scene.", .write)
        case .sceneNext: descriptor(["scene", "next"], "Switch to the next scene.", .write)
        case .scenePrevious:
            descriptor(["scene", "previous"], "Switch to the previous scene.", .write)
        }
    }

    private func descriptor(_ path: [String], _ summary: String, _ effect: UserOperationEffect)
        -> UserOperationDescriptor
    {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "virtualCamera.\(rawValue)"), summary: summary,
            cli: ["camera"] + path, effect: effect)
    }
}

public struct VirtualCameraClient: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct VirtualCameraSnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var helperRunning: Bool
    public var extensionInstalled: Bool
    public var extensionBuild: String?
    public var clients: [VirtualCameraClient]
    public var live: Bool
    public var framesPerSecond: Double
    public var source: VirtualCameraSource?
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var sources: [VirtualCameraSource]
    public var format: VirtualCameraFormat
    public var cameraAccess: String
    public var state: VirtualCameraState
    public var message: String?

    public init(
        enabled: Bool, helperRunning: Bool, extensionInstalled: Bool, extensionBuild: String? = nil,
        clients: [VirtualCameraClient] = [], live: Bool = false, framesPerSecond: Double = 0,
        source: VirtualCameraSource? = nil, sourceWidth: Int = 0, sourceHeight: Int = 0,
        sources: [VirtualCameraSource] = [], format: VirtualCameraFormat = .standard,
        cameraAccess: String = "unknown", state: VirtualCameraState, message: String? = nil
    ) {
        self.enabled = enabled
        self.helperRunning = helperRunning
        self.extensionInstalled = extensionInstalled
        self.extensionBuild = extensionBuild
        self.clients = clients
        self.live = live
        self.framesPerSecond = framesPerSecond
        self.source = source
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sources = sources
        self.format = format
        self.cameraAccess = cameraAccess
        self.state = state
        self.message = message
    }

    public static func stored(
        _ defaults: UserDefaults = SharedDefaults.store, helperRunning: Bool = false
    ) -> VirtualCameraSnapshot {
        VirtualCameraSnapshot(
            enabled: VirtualCameraStore.isEnabled(defaults), helperRunning: helperRunning,
            extensionInstalled: false, state: VirtualCameraStore.load(defaults))
    }

    public var inUse: Bool { !clients.isEmpty }

    public var headline: String {
        if !enabled { return "Off" }
        if !helperRunning { return "Waiting for Edith" }
        if !extensionInstalled { return "Camera extension not installed" }
        if state.privacy != .live, inUse { return "Paused: \(state.privacy.title)" }
        if live { return "Live in " + clients.map(\.name).joined(separator: ", ") }
        return "Ready, no app is using it"
    }

    public var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String?) -> VirtualCameraSnapshot? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(VirtualCameraSnapshot.self, from: Data(text.utf8))
    }

    public func resultPayload(requestID: String?, error: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [VirtualCameraIPC.okKey: error == nil]
        if let requestID { payload[VirtualCameraIPC.requestIDKey] = requestID }
        if let encoded { payload[VirtualCameraIPC.snapshotKey] = encoded }
        if let error { payload[VirtualCameraIPC.errorKey] = error }
        return payload
    }
}

public struct VirtualCameraRuntimeRequest: Equatable, Sendable {
    public let request: VirtualCameraRequest
    public let requestID: String
    public let deadline: Date

    public init(
        request: VirtualCameraRequest, requestID: String = UUID().uuidString, deadline: Date
    ) {
        self.request = request
        self.requestID = requestID
        self.deadline = deadline
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let text = payload[VirtualCameraIPC.requestKey] as? String,
            let request = VirtualCameraRequest.decode(text),
            let requestID = payload[VirtualCameraIPC.requestIDKey] as? String,
            UUID(uuidString: requestID) != nil,
            let deadline = payload[VirtualCameraIPC.deadlineKey] as? TimeInterval,
            deadline.isFinite
        else { return nil }
        self.init(
            request: request, requestID: requestID, deadline: Date(timeIntervalSince1970: deadline))
    }

    public var payload: [String: Any]? {
        guard let encoded = request.encoded else { return nil }
        return [
            VirtualCameraIPC.requestKey: encoded,
            VirtualCameraIPC.requestIDKey: requestID,
            VirtualCameraIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public func isLive(at now: Date = Date()) -> Bool { now < deadline }
}

public struct VirtualCameraOperationFailure: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

private final class VirtualCameraReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String]?, Never>?
    private var result: [String: String]??

    func wait(timeout: Duration) async -> [String: String]? {
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.finish(nil)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock { () -> [String: String]?? in
                    if let result { return result }
                    self.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            self.finish(nil)
        }
    }

    func finish(_ value: [String: String]?) {
        let waiting = lock.withLock { () -> CheckedContinuation<[String: String]?, Never>? in
            guard result == nil else { return nil }
            result = .some(value)
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(returning: value)
    }
}

public enum VirtualCameraOperationExecution {
    public static var extensionEntry: ExtensionRegistryEntry? {
        ExtensionRegistry.entries.first { $0.defaultsKey == AppStorageKeys.VirtualCamera.enabled }
    }

    public static func request(
        _ request: VirtualCameraRequest, timeout: Duration = .seconds(10)
    ) async throws -> VirtualCameraSnapshot {
        let seconds = Double(timeout.components.seconds)
        let runtime = VirtualCameraRuntimeRequest(
            request: request, deadline: Date().addingTimeInterval(seconds))
        guard let payload = runtime.payload else {
            throw VirtualCameraOperationFailure("The camera request could not be encoded.")
        }
        let reply = VirtualCameraReply()
        let token = DistributedNotificationCenter.default().addObserver(
            forName: IPC.Name.virtualCameraActionResult, object: nil, queue: nil
        ) { notification in
            let info = notification.userInfo ?? [:]
            guard info[VirtualCameraIPC.requestIDKey] as? String == runtime.requestID else {
                return
            }
            var flattened: [String: String] = [:]
            for (key, value) in info {
                guard let key = key as? String else { continue }
                if let text = value as? String { flattened[key] = text }
                if let flag = value as? Bool { flattened[key] = flag ? "true" : "false" }
            }
            reply.finish(flattened)
        }
        defer { DistributedNotificationCenter.default().removeObserver(token) }
        IPC.post(IPC.Name.requestVirtualCameraAction, userInfo: payload)
        guard let response = await reply.wait(timeout: timeout) else {
            if Task.isCancelled { throw CancellationError() }
            throw VirtualCameraOperationFailure("Edith did not answer the camera request in time.")
        }
        guard response[VirtualCameraIPC.okKey] == "true" else {
            throw VirtualCameraOperationFailure(
                response[VirtualCameraIPC.errorKey] ?? "The camera request failed.")
        }
        guard let snapshot = VirtualCameraSnapshot.decode(response[VirtualCameraIPC.snapshotKey])
        else {
            throw VirtualCameraOperationFailure("Edith sent an unreadable camera status.")
        }
        return snapshot
    }
}
