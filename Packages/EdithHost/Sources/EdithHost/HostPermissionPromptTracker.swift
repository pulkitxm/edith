import EdithExtensionSupport
import Foundation

@MainActor
enum HostPermissionPromptTracker {
    static let hintThreshold = 2
    static let countKey = "permissionPromptCount"
    static let hintShownKey = "permissionHintShown"
    static var hintDue: (() -> Void)?

    static func shouldHint(count: Int, alreadyShown: Bool) -> Bool {
        !alreadyShown && count >= hintThreshold
    }

    static func record(defaults: UserDefaults = SharedDefaults.store) {
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        guard shouldHint(count: count, alreadyShown: defaults.bool(forKey: hintShownKey))
        else { return }
        defaults.set(true, forKey: hintShownKey)
        hintDue?()
    }
}
