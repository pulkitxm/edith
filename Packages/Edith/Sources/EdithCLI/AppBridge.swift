import AppKit
import EdithKit
import Foundation

public enum AppBridge {
    public static let helperBundleID = MainApp.statusBarBundleIdentifier
    public static let mainBundleID = MainApp.bundleIdentifier
    public static var helperIsRunning: Bool { CLIEnvironment.isHelperRunning() }

    public static var mainAppIsRunning: Bool { CLIEnvironment.isMainAppRunning() }

    public static func requireHelper(_ what: String) throws {
        guard helperIsRunning else {
            throw CLIFailure.unavailable(
                "\(what) needs the Edith menu bar app to be running",
                hint: "start Edith, then retry")
        }
    }

    public static func requireMainApp(_ what: String) throws {
        guard mainAppIsRunning else {
            throw CLIFailure.unavailable(
                "\(what) needs the Edith main window to be open",
                hint: "run `ed app relaunch --yes`, or open Edith from the menu bar")
        }
    }

    public static func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        CLIEnvironment.deliver(name, userInfo)
    }

    public static func silence(
        _ what: String, extensionKey: String? = nil, permission: String? = nil
    ) -> CLIFailure {
        guard helperIsRunning else {
            return CLIFailure.unavailable(
                "Edith is not running, so it cannot answer for \(what)",
                hint: "open Edith and try again")
        }
        if let extensionKey,
            !(CLIEnvironment.sharedDefaults.object(forKey: extensionKey) as? Bool ?? false)
        {
            return CLIFailure.unavailable(
                "the extension behind \(what) is off",
                hint: "run `ed extensions ls` to see which are enabled")
        }
        if let permission,
            let usage = CLIEnvironment.permissionUsages().first(where: {
                $0.permission.rawValue == permission
            }), !usage.isGranted
        {
            return CLIFailure.unavailable(
                "macOS has not granted Edith access for \(what)",
                hint: "run `ed permissions request \(permission)`")
        }
        return CLIFailure.unavailable(
            "Edith did not answer for \(what) in time",
            hint: "the running app may predate this command; rebuild and reopen Edith")
    }

    public static func awaitReply(
        _ name: Notification.Name, timeout: TimeInterval,
        waitingMessage: String? = "waiting for Edith to answer...",
        matching: @escaping ([AnyHashable: Any]) -> Bool = { _ in true },
        trigger: @escaping @Sendable () -> Void
    ) async -> [AnyHashable: Any]? {
        if let answer = CLIEnvironment.answer {
            trigger()
            guard let payload = answer(name), matching(payload) else { return nil }
            return payload
        }
        return await IPCReplyAwaiter.awaitReply(
            name, timeout: timeout, matching: matching,
            waiting: { if let waitingMessage { CLIOut.note(waitingMessage) } }, trigger: trigger)
    }
}
