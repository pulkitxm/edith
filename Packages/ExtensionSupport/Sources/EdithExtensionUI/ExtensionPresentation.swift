import EdithExtensionCore
import Foundation

public enum ExtensionPresentation {
    public static let showWindowNotification = ExtensionWindowRequest.notification

    public static func showWindow(image: UnsafeRawPointer = #dsohandle) {
        ExtensionWindowRequest.post(image: image)
    }
}
