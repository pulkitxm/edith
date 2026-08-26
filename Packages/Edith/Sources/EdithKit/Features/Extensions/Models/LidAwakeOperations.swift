import Combine
import EdithCore
import Foundation

public enum LidAwakeOperation: String, CaseIterable, Equatable, Sendable {
    case status
    case on
    case off
    case battery
    case restoreOnQuit

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            descriptor("status", "Show the live Lid Awake state.", effect: .read)
        case .on:
            descriptor(
                "on", "Keep running with the lid closed.", effect: .destructive,
                requiresPreview: true)
        case .off:
            descriptor("off", "Restore normal lid-close sleep.", effect: .write)
        case .battery:
            descriptor("battery", "Set the low-battery auto-pause percentage.", effect: .write)
        case .restoreOnQuit:
            descriptor(
                "restore-on-quit", "Choose whether quitting restores normal sleep.",
                effect: .destructive, requiresPreview: true)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect,
        requiresPreview: Bool = false
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "lidAwake.\(rawValue)"), summary: summary,
            cli: ["lid-awake", verb], effect: effect, requiresPreview: requiresPreview)
    }
}

public enum LidAwakeRequest: Equatable, Sendable {
    case status
    case on(LidAwakeSession)
    case off
    case enableExtension
    case disableExtension
    case setBatteryThreshold(Int)
    case setRestoreOnQuit(Bool)

    public init?(runtimePayload: [AnyHashable: Any]) {
        guard let rawAction = runtimePayload[LidAwakeIPC.actionKey] as? String,
            let action = LidAwakeIPC.Action(rawValue: rawAction)
        else { return nil }
        switch action {
        case .status:
            self = .status
        case .on:
            guard let rawSession = runtimePayload[LidAwakeIPC.sessionKey] as? String,
                let session = LidAwakeSession(rawValue: rawSession)
            else { return nil }
            self = .on(session)
        case .off:
            self = .off
        case .enableExtension:
            self = .enableExtension
        case .disableExtension:
            self = .disableExtension
        }
    }

    public var operation: LidAwakeOperation? {
        switch self {
        case .status: .status
        case .on: .on
        case .off: .off
        case .enableExtension, .disableExtension: nil
        case .setBatteryThreshold: .battery
        case .setRestoreOnQuit: .restoreOnQuit
        }
    }

    public var runtimePayload: [String: Any]? {
        switch self {
        case .status:
            [LidAwakeIPC.actionKey: LidAwakeIPC.Action.status.rawValue]
        case .on(let session):
            [
                LidAwakeIPC.actionKey: LidAwakeIPC.Action.on.rawValue,
                LidAwakeIPC.sessionKey: session.rawValue,
            ]
        case .off:
            [LidAwakeIPC.actionKey: LidAwakeIPC.Action.off.rawValue]
        case .enableExtension:
            [LidAwakeIPC.actionKey: LidAwakeIPC.Action.enableExtension.rawValue]
        case .disableExtension:
            [LidAwakeIPC.actionKey: LidAwakeIPC.Action.disableExtension.rawValue]
        case .setBatteryThreshold, .setRestoreOnQuit:
            nil
        }
    }
}

public struct LidAwakeRuntimeRequestContext: Equatable, Sendable {
    public let requestID: String
    public let deadline: Date

    public init?(runtimePayload: [AnyHashable: Any]) {
        guard let requestID = runtimePayload[LidAwakeIPC.requestIDKey] as? String,
            let deadline = runtimePayload[LidAwakeIPC.deadlineKey] as? TimeInterval
        else { return nil }
        self.init(requestID: requestID, deadline: Date(timeIntervalSince1970: deadline))
    }

    public init?(requestID: String = UUID().uuidString, deadline: Date) {
        guard !requestID.isEmpty, UUID(uuidString: requestID) != nil,
            deadline.timeIntervalSince1970.isFinite
        else { return nil }
        self.requestID = requestID
        self.deadline = deadline
    }

    public init?(
        requestID: String = UUID().uuidString, timeout: Duration, now: Date = Date()
    ) {
        let components = timeout.components
        let seconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let nowValue = now.timeIntervalSince1970
        let deadlineValue = nowValue + max(0, seconds)
        guard seconds.isFinite, nowValue.isFinite, deadlineValue.isFinite else { return nil }
        self.init(requestID: requestID, deadline: Date(timeIntervalSince1970: deadlineValue))
    }

    public var runtimePayload: [String: Any] {
        [
            LidAwakeIPC.requestIDKey: requestID,
            LidAwakeIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public func isLive(at now: Date = Date()) -> Bool {
        now < deadline
    }

    public func remainingTimeInterval(at now: Date = Date()) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }
}

public struct LidAwakeRuntimeRequest: Equatable, Sendable {
    public let request: LidAwakeRequest
    public let context: LidAwakeRuntimeRequestContext

    public init?(runtimePayload: [AnyHashable: Any]) {
        guard let request = LidAwakeRequest(runtimePayload: runtimePayload),
            let context = LidAwakeRuntimeRequestContext(runtimePayload: runtimePayload)
        else { return nil }
        self.request = request
        self.context = context
    }
}

public struct LidAwakeSnapshot: Equatable, Sendable {
    public var extensionEnabled: Bool
    public var active: Bool
    public var requestedActive: Bool
    public var applying: Bool
    public var batterySuspended: Bool
    public var session: LidAwakeSession
    public var remainingSeconds: Double?
    public var batteryThreshold: Int
    public var restoreOnQuit: Bool
    public var helperStatus: String
    public var appRunning: Bool
    public var lastError: String?

    public init(
        extensionEnabled: Bool, active: Bool, requestedActive: Bool, applying: Bool,
        batterySuspended: Bool, session: LidAwakeSession, remainingSeconds: Double? = nil,
        batteryThreshold: Int, restoreOnQuit: Bool, helperStatus: String, appRunning: Bool,
        lastError: String? = nil
    ) {
        self.extensionEnabled = extensionEnabled
        self.active = active
        self.requestedActive = requestedActive
        self.applying = applying
        self.batterySuspended = batterySuspended
        self.session = session
        self.remainingSeconds = remainingSeconds
        self.batteryThreshold = batteryThreshold
        self.restoreOnQuit = restoreOnQuit
        self.helperStatus = helperStatus
        self.appRunning = appRunning
        self.lastError = lastError
    }

    public init(
        storedIn defaults: UserDefaults = SharedDefaults.store, appRunning: Bool = false,
        helperStatus: String = "unavailable"
    ) {
        let active = defaults.bool(forKey: LidAwakeState.activeKey)
        self.init(
            extensionEnabled: LidAwakeState.isEnabled(defaults), active: active,
            requestedActive: active, applying: false, batterySuspended: false,
            session: LidAwakeState.session(defaults),
            batteryThreshold: LidAwakeState.batteryThreshold(defaults),
            restoreOnQuit: LidAwakeState.restoresOnQuit(defaults), helperStatus: helperStatus,
            appRunning: appRunning)
    }

    public init(payload: [AnyHashable: Any], fallback: LidAwakeSnapshot) {
        self.init(
            extensionEnabled: payload["extensionEnabled"] as? Bool ?? fallback.extensionEnabled,
            active: payload["active"] as? Bool ?? fallback.active,
            requestedActive: payload["requestedActive"] as? Bool ?? fallback.requestedActive,
            applying: payload["applying"] as? Bool ?? fallback.applying,
            batterySuspended: payload["batterySuspended"] as? Bool ?? fallback.batterySuspended,
            session: (payload["session"] as? String).flatMap(LidAwakeSession.init(rawValue:))
                ?? fallback.session,
            remainingSeconds: (payload["remainingSeconds"] as? NSNumber)?.doubleValue,
            batteryThreshold: payload["batteryThreshold"] as? Int ?? fallback.batteryThreshold,
            restoreOnQuit: payload["restoreOnQuit"] as? Bool ?? fallback.restoreOnQuit,
            helperStatus: payload["helperStatus"] as? String ?? fallback.helperStatus,
            appRunning: payload["appRunning"] as? Bool ?? fallback.appRunning,
            lastError: payload["lastError"] as? String ?? fallback.lastError)
    }

    public var payload: [String: Any] {
        var result: [String: Any] = [
            "extensionEnabled": extensionEnabled,
            "active": active,
            "requestedActive": requestedActive,
            "applying": applying,
            "batterySuspended": batterySuspended,
            "session": session.rawValue,
            "batteryThreshold": batteryThreshold,
            "restoreOnQuit": restoreOnQuit,
            "helperStatus": helperStatus,
            "appRunning": appRunning,
        ]
        if let remainingSeconds { result["remainingSeconds"] = remainingSeconds }
        if let lastError { result["lastError"] = lastError }
        return result
    }

    public func resultPayload(
        _ outcome: LidAwakeOutcome, requestID: String? = nil
    ) -> [String: Any] {
        var result = payload
        if let requestID { result[LidAwakeIPC.requestIDKey] = requestID }
        switch outcome {
        case .applied:
            result[LidAwakeIPC.okKey] = true
        case .failed(let message):
            result[LidAwakeIPC.okKey] = false
            result[LidAwakeIPC.errorKey] = message
        }
        return result
    }
}

public struct LidAwakeOperationPreview: Equatable, Sendable {
    public let operation: LidAwakeOperation
    public let summary: String
    public let warning: String

    public init(operation: LidAwakeOperation, summary: String, warning: String) {
        self.operation = operation
        self.summary = summary
        self.warning = warning
    }
}

public struct LidAwakeSettingChange: Equatable, Sendable {
    public let operation: LidAwakeOperation
    public let key: String
    public let value: JSONValue

    public init(operation: LidAwakeOperation, key: String, value: JSONValue) {
        self.operation = operation
        self.key = key
        self.value = value
    }
}

public struct LidAwakeOperationFailure: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

private struct LidAwakeRuntimePayload: @unchecked Sendable {
    let value: [AnyHashable: Any]
}

private final class LidAwakeRuntimeReply: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<LidAwakeRuntimePayload?, Never>)
        case finished(LidAwakeRuntimePayload?)
    }

    private let lock = NSLock()
    private var state = State.pending

    func wait(timeout: Duration) async -> [AnyHashable: Any]? {
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self.finish(nil)
        }
        defer { timeoutTask.cancel() }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { install($0) }
        } onCancel: {
            self.finish(nil)
        }
        return result?.value
    }

    func deliver(_ payload: [AnyHashable: Any]) {
        finish(LidAwakeRuntimePayload(value: payload))
    }

    private func install(_ continuation: CheckedContinuation<LidAwakeRuntimePayload?, Never>) {
        var result: LidAwakeRuntimePayload??
        lock.lock()
        switch state {
        case .pending:
            state = .waiting(continuation)
        case .waiting:
            result = .some(nil)
        case .finished(let finished):
            result = .some(finished)
        }
        lock.unlock()
        if let result { continuation.resume(returning: result) }
    }

    private func finish(_ payload: LidAwakeRuntimePayload?) {
        var continuation: CheckedContinuation<LidAwakeRuntimePayload?, Never>?
        lock.lock()
        switch state {
        case .pending:
            state = .finished(payload)
        case .waiting(let waiting):
            state = .finished(payload)
            continuation = waiting
        case .finished:
            lock.unlock()
            return
        }
        lock.unlock()
        continuation?.resume(returning: payload)
    }
}

@MainActor
public final class LidAwakeOperationModel: ObservableObject {
    public typealias Performer = @Sendable (LidAwakeRequest) async throws -> LidAwakeSnapshot

    @Published public private(set) var applying = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var lastSnapshot: LidAwakeSnapshot?

    private let performer: Performer
    private var task: Task<Void, Never>?
    private var generation: UInt = 0

    public init(
        performer: @escaping Performer = {
            try await LidAwakeOperationExecution.request($0)
        }
    ) {
        self.performer = performer
    }

    @discardableResult
    public func perform(_ request: LidAwakeRequest) -> Task<Void, Never>? {
        guard !applying else { return nil }
        task?.cancel()
        generation &+= 1
        let generation = generation
        applying = true
        errorMessage = nil
        let task = Task { @MainActor [weak self, performer] in
            do {
                let snapshot = try await performer(request)
                guard let self, self.generation == generation else { return }
                lastSnapshot = snapshot
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                errorMessage = error.localizedDescription
            }
            guard let self, self.generation == generation else { return }
            applying = false
        }
        self.task = task
        return task
    }

    @discardableResult
    public func refreshStatus() -> Task<Void, Never>? {
        guard !applying else { return nil }
        task?.cancel()
        generation &+= 1
        let generation = generation
        let task = Task { @MainActor [weak self, performer] in
            do {
                let snapshot = try await performer(.status)
                guard let self, self.generation == generation else { return }
                lastSnapshot = snapshot
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
        self.task = task
        return task
    }

    public func clearError() {
        errorMessage = nil
        lastSnapshot?.lastError = nil
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        applying = false
    }
}

public enum LidAwakeOperationExecution {
    public static var extensionEntry: ExtensionRegistryEntry? {
        ExtensionRegistry.entries.first { $0.defaultsKey == LidAwakeState.enabledKey }
    }

    @discardableResult
    public static func enableExtension(
        using mutationCenter: ExtensionMutationCenter = ExtensionMutationCenter()
    ) -> ExtensionMutationResult? {
        guard let extensionEntry else { return nil }
        return mutationCenter.setEnabled(true, for: extensionEntry)
    }

    public static func preview(for request: LidAwakeRequest) -> LidAwakeOperationPreview? {
        switch request {
        case .on(let session):
            LidAwakeOperationPreview(
                operation: .on,
                summary:
                    "Keep this Mac running with the lid closed for \(session.title.lowercased()).",
                warning:
                    "The Mac will keep drawing power and shedding heat. Do not put it in a bag.")
        case .setRestoreOnQuit(false):
            LidAwakeOperationPreview(
                operation: .restoreOnQuit,
                summary: "Leave lid-close sleep disabled when Edith quits.",
                warning: "Normal lid-close sleep must then be restored manually.")
        case .status, .off, .enableExtension, .disableExtension, .setBatteryThreshold,
            .setRestoreOnQuit(true):
            nil
        }
    }

    public static func request(
        _ request: LidAwakeRequest, defaults: UserDefaults = SharedDefaults.store,
        timeout: Duration = .seconds(30)
    ) async throws -> LidAwakeSnapshot {
        guard var payload = request.runtimePayload else {
            throw LidAwakeOperationFailure("The Lid Awake request is not a runtime action.")
        }
        guard let context = LidAwakeRuntimeRequestContext(timeout: timeout) else {
            throw LidAwakeOperationFailure("The Lid Awake request deadline is invalid.")
        }
        payload.merge(context.runtimePayload) { _, new in new }
        let reply = LidAwakeRuntimeReply()
        let token = DistributedNotificationCenter.default().addObserver(
            forName: IPC.Name.lidAwakeActionResult, object: nil, queue: nil
        ) { notification in
            let payload = notification.userInfo ?? [:]
            guard payload[LidAwakeIPC.requestIDKey] as? String == context.requestID else { return }
            reply.deliver(payload)
        }
        defer { DistributedNotificationCenter.default().removeObserver(token) }
        IPC.post(IPC.Name.requestLidAwakeAction, userInfo: payload)
        guard let response = await reply.wait(timeout: timeout) else {
            if Task.isCancelled { throw CancellationError() }
            throw LidAwakeOperationFailure("Edith did not answer the Lid Awake request in time.")
        }
        guard response[LidAwakeIPC.okKey] as? Bool == true else {
            throw LidAwakeOperationFailure(
                response[LidAwakeIPC.errorKey] as? String
                    ?? "Lid Awake could not change state.")
        }
        return LidAwakeSnapshot(
            payload: response,
            fallback: LidAwakeSnapshot(storedIn: defaults, appRunning: true))
    }

    public static func settingChange(for request: LidAwakeRequest) -> LidAwakeSettingChange? {
        switch request {
        case .setBatteryThreshold(let threshold)
        where LidAwakeState.isValidBatteryThreshold(threshold):
            LidAwakeSettingChange(
                operation: .battery, key: LidAwakeState.batteryThresholdKey,
                value: .int(threshold))
        case .setRestoreOnQuit(let enabled):
            LidAwakeSettingChange(
                operation: .restoreOnQuit, key: LidAwakeState.restoreOnQuitKey,
                value: .bool(enabled))
        case .status, .on, .off, .enableExtension, .disableExtension, .setBatteryThreshold:
            nil
        }
    }

    @discardableResult
    public static func applySetting(
        _ request: LidAwakeRequest, defaults: UserDefaults = SharedDefaults.store
    ) -> Bool {
        guard let change = settingChange(for: request) else { return false }
        if case .setRestoreOnQuit(let enabled) = request {
            defaults.set(enabled, forKey: change.key)
            defaults.synchronize()
            return true
        }
        do {
            try ConfigurationExecutor(
                shared: defaults, standard: defaults, announceChange: {}
            ).set(change.value, forKey: change.key, announce: false)
            return true
        } catch {
            return false
        }
    }

    public static func deadline(for timeout: Duration, now: Date = Date()) -> Date {
        LidAwakeRuntimeRequestContext(timeout: timeout, now: now)?.deadline ?? now
    }
}
