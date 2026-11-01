import Foundation

public enum ExtensionWindowRequest {
    public static let notification = Notification.Name("edith.extension.showWindow")

    public static func post() {
        NotificationCenter.default.post(
            name: notification, object: nil,
            userInfo: ["owner": ExtensionScope.installed["EDITH_EXTENSION_ID"] ?? ""])
    }
}
