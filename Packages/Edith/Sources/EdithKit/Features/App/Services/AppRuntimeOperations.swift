import AppKit
import EdithCore
import Foundation

public enum AppRuntimeOwner: String, Equatable, Sendable {
    case menuBar
    case mainApp
    case local
}

public enum KeyboardCleaningState: String, Equatable, Sendable {
    case arming
    case cleaning
    case inputMonitoringRequired
    case accessibilityRequired
    case unavailable

    public var accepted: Bool {
        self == .arming || self == .cleaning
    }
}

public enum KeyboardCleaningIPC {
    public static let requestIDKey = "requestID"
    public static let stateKey = "state"

    public static func payload(
        requestID: String, state: KeyboardCleaningState
    ) -> [String: Any] {
        [requestIDKey: requestID, stateKey: state.rawValue]
    }

    public static func state(from payload: [AnyHashable: Any]) -> KeyboardCleaningState? {
        guard let raw = payload[stateKey] as? String else { return nil }
        return KeyboardCleaningState(rawValue: raw)
    }
}

public enum AppRuntimeOperation: String, CaseIterable, Sendable {
    case cleanKeys
    case testNotification
    case open
    case quit
    case checkUpdates
    case updateHistory
    case relaunch
    case clearUpdateHistory
    case reveal
    case snapshot

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .cleanKeys:
            descriptor(
                "app.clean-keys", "Lock the keyboard for cleaning.", "clean-keys", .interactive)
        case .testNotification:
            descriptor(
                "app.test-notification", "Send a test notification.", "test-notification",
                .interactive)
        case .open:
            descriptor("app.open", "Open the Edith panel.", "open", .interactive)
        case .quit:
            descriptor("app.quit", "Quit the Edith main app.", "quit", .destructive, preview: true)
        case .checkUpdates:
            descriptor("app.check-updates", "Check for an Edith update.", "check-updates", .write)
        case .updateHistory:
            descriptor("app.update-history", "Read the update check history.", "updates", .read)
        case .relaunch:
            descriptor(
                "app.relaunch", "Quit and relaunch Edith.", "relaunch", .destructive, preview: true)
        case .clearUpdateHistory:
            descriptor(
                "app.clear-updates", "Clear the update check history.", "clear-updates",
                .destructive, preview: true)
        case .reveal:
            descriptor("app.reveal", "Reveal an Edith section.", "reveal", .interactive)
        case .snapshot:
            descriptor("app.snapshot", "Capture Edith windows as images.", "snapshot", .write)
        }
    }

    public var owner: AppRuntimeOwner {
        switch self {
        case .cleanKeys, .testNotification, .open: .menuBar
        case .quit, .checkUpdates, .reveal, .snapshot: .mainApp
        case .updateHistory, .relaunch, .clearUpdateHistory: .local
        }
    }

    public var notification: Notification.Name? {
        switch self {
        case .cleanKeys: IPC.Name.requestKeyboardClean
        case .testNotification: IPC.Name.requestTestNotification
        case .open: IPC.Name.openPanel
        case .quit: IPC.Name.quitMainApp
        case .checkUpdates: IPC.Name.requestUpdateCheck
        case .reveal: IPC.Name.requestReveal
        case .snapshot: IPC.Name.requestWindowSnapshot
        case .updateHistory, .relaunch, .clearUpdateHistory: nil
        }
    }

    private func descriptor(
        _ id: String, _ summary: String, _ command: String, _ effect: UserOperationEffect,
        preview: Bool = false
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: id), summary: summary, cli: ["app", command],
            effect: effect, requiresPreview: preview)
    }
}

public struct AppRuntimeRequest {
    public let operation: AppRuntimeOperation
    public let userInfo: [String: Any]

    public init(_ operation: AppRuntimeOperation, userInfo: [String: Any] = [:]) {
        self.operation = operation
        self.userInfo = userInfo
    }
}

public struct AppRuntimeCenter {
    public typealias Post = (Notification.Name, [String: Any]?) -> Void
    public typealias WillPerform = (AppRuntimeOperation) -> Void

    private let post: Post
    private let willPerform: WillPerform

    public init(
        post: @escaping Post = { IPC.post($0, userInfo: $1) },
        willPerform: @escaping WillPerform = { _ in }
    ) {
        self.post = post
        self.willPerform = willPerform
    }

    public func request(_ request: AppRuntimeRequest) {
        guard let notification = request.operation.notification else { return }
        willPerform(request.operation)
        post(notification, request.userInfo.isEmpty ? nil : request.userInfo)
    }

    public func request(_ operation: AppRuntimeOperation, userInfo: [String: Any] = [:]) {
        request(AppRuntimeRequest(operation, userInfo: userInfo))
    }

    public func perform<Result>(
        _ operation: AppRuntimeOperation, action: () throws -> Result
    ) rethrows -> Result {
        willPerform(operation)
        return try action()
    }

    public func perform<Result>(
        _ operation: AppRuntimeOperation, action: () async throws -> Result
    ) async rethrows -> Result {
        willPerform(operation)
        return try await action()
    }

    public func relaunchCurrentApplication(
        at bundleURL: URL, launch: (URL) -> Void, terminate: () -> Void
    ) {
        perform(.relaunch) {
            launch(bundleURL)
            terminate()
        }
    }

    @MainActor
    public func relaunchCurrentApplication(at bundleURL: URL = Bundle.main.bundleURL) {
        relaunchCurrentApplication(
            at: bundleURL,
            launch: { url in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            },
            terminate: { NSApp.terminate(nil) })
    }

    public func quitCompletely(terminate: () -> Void) {
        request(.quit)
        terminate()
    }

    @MainActor
    public func quitCompletely() {
        quitCompletely(terminate: { NSApp.terminate(nil) })
    }

    public func updateHistory(limit: Int? = nil, url: URL = UpdateCheckLog.url)
        -> [UpdateCheckRecord]
    {
        willPerform(.updateHistory)
        let records = UpdateCheckLog.load(from: url)
        guard let limit else { return records }
        return Array(records.prefix(max(0, limit)))
    }

    @discardableResult
    public func clearUpdateHistory(url: URL = UpdateCheckLog.url) -> Int {
        willPerform(.clearUpdateHistory)
        let count = UpdateCheckLog.load(from: url).count
        UpdateCheckLog.clear(at: url)
        return count
    }
}
