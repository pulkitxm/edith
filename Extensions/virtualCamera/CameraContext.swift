import EdithExtensionSupport
import Foundation

public enum DataRoot {
    public static var virtualCamera: URL { ExtensionData.root }
}

public enum AppBuildIdentity {
    public static var application: String {
        ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"]
            ?? "org.example.camera.tests"
    }
    public static var developmentSlot: String? {
        VirtualCameraIdentity.slot(ofApplication: application)
    }
    public static func slot(of identifier: String) -> String? {
        VirtualCameraIdentity.slot(ofApplication: identifier)
    }
    public static var isDevelopment: Bool {
        application != VirtualCameraIdentity.productionApplication
    }
}

private final class CameraResourcesMarker: NSObject {}

public enum BundledResources {
    public static func url(forResource name: String, withExtension suffix: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: suffix)
        #else
        return Bundle(for: CameraResourcesMarker.self).url(forResource: name, withExtension: suffix)
        #endif
    }
}

public enum IPC {
    public enum Name: String {
        case requestVirtualCameraAction, virtualCameraActionResult, virtualCameraStateChanged
        case virtualCameraStatusChanged, requestCameraExtensionAction, cameraExtensionActionResult
        var notification: Notification.Name { .init("edith.camera.local." + rawValue) }
    }

    public static func observe(_ name: Name, info: @escaping ([AnyHashable: Any]) -> Void)
        -> NSObjectProtocol
    {
        NotificationCenter.default.addObserver(
            forName: name.notification, object: nil, queue: .main
        ) {
            info($0.userInfo ?? [:])
        }
    }

    public static func post(_ name: Name, userInfo: [AnyHashable: Any]) {
        NotificationCenter.default.post(name: name.notification, object: nil, userInfo: userInfo)
    }

    public static func stopObserving(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }
}
