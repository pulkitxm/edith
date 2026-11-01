import Foundation

public enum ExtensionWindowRequest {
    public static let notification = Notification.Name("edith.extension.showWindow")

    public static func post(image: UnsafeRawPointer = #dsohandle) {
        NotificationCenter.default.post(
            name: notification, object: nil,
            userInfo: ["owner": ExtensionScope.resolve(image)["EDITH_EXTENSION_ID"] ?? ""])
    }
}
