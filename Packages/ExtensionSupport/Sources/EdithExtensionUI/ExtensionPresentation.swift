import EdithExtensionSupport
import Foundation

public enum ExtensionPresentation {
    public static let showWindowNotification = ExtensionWindowRequest.notification

    public static func showWindow() { ExtensionWindowRequest.post() }
}
