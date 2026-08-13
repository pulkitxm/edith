import Foundation

public enum PermissionPromptTracker {
    public static let hintThreshold = 2
    public static let countKey = "permissionPromptCount"
    public static let hintShownKey = "permissionHintShown"

    public static func shouldHint(count: Int, alreadyShown: Bool) -> Bool {
        !alreadyShown && count >= hintThreshold
    }

    @discardableResult
    public static func record() -> Bool {
        let defaults = SharedDefaults.store
        let count = defaults.integer(forKey: countKey) + 1
        defaults.set(count, forKey: countKey)
        guard shouldHint(count: count, alreadyShown: defaults.bool(forKey: hintShownKey))
        else { return false }
        defaults.set(true, forKey: hintShownKey)
        IPC.post(IPC.Name.permissionHintDue)
        return true
    }
}
