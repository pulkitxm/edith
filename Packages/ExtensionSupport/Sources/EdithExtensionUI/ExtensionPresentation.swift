import Foundation

public enum ExtensionPresentation {
    public static let showWindowNotification = Notification.Name("edith.extension.showWindow")

    public static func showWindow() {
        NotificationCenter.default.post(name: showWindowNotification, object: nil)
    }
}
