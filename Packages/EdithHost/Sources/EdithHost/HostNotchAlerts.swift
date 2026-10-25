import EdithExtensionSupport
import Foundation
import UserNotifications

enum HostPermissionPromptTracker {
    static let hintThreshold = 2
    static let countKey = "permissionPromptCount"
    static let hintShownKey = "permissionHintShown"
    static let hintDue = "com.pulkit.edith.permissionHintDue"

    static func shouldHint(count: Int, alreadyShown: Bool) -> Bool {
        !alreadyShown && count >= hintThreshold
    }

    @discardableResult
    static func record(defaults: UserDefaults = SharedDefaults.store) -> Bool {
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        guard shouldHint(count: count, alreadyShown: defaults.bool(forKey: hintShownKey))
        else { return false }
        defaults.set(true, forKey: hintShownKey)
        IPC.post(hintDue)
        return true
    }
}

@MainActor final class HostNotchAlerts {
    static let updateIdentifier = "update_ready"

    static func updateTitle(for version: String) -> String { "Edith \(version) is ready" }
    static let updateBody = "Quit and reopen Edith to finish updating."

    static func notificationName(namespace: String) -> Notification.Name {
        .init(namespace + ".notchAlert")
    }

    private let namespace: String
    private let version: () -> String?
    private let notify: @MainActor (String) -> Void
    private var observers: [NSObjectProtocol] = []

    init(
        namespace: String, version: @escaping () -> String?,
        notify: @escaping @MainActor (String) -> Void = HostNotchAlerts.postUserNotification
    ) {
        self.namespace = namespace
        self.version = version
        self.notify = notify
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            IPC.observe(HostUpdateEvents.ready) { [weak self] in
                MainActor.assumeIsolated { self?.updateReady() }
            },
            IPC.observe(HostPermissionPromptTracker.hintDue) { [weak self] in
                MainActor.assumeIsolated { self?.forward(["kind": "permissionHint"]) }
            },
        ]
    }

    func stop() {
        for observer in observers { IPC.stopObserving(observer) }
        observers = []
    }

    private func updateReady() {
        guard let version = version(), !version.isEmpty else { return }
        forward(["kind": "updateReady", "version": version])
        notify(version)
    }

    private func forward(_ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.notificationName(namespace: namespace), object: nil, userInfo: info,
            deliverImmediately: true)
    }

    static func postUserNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = updateTitle(for: version)
        content.body = updateBody
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: updateIdentifier, content: content, trigger: nil))
    }
}
