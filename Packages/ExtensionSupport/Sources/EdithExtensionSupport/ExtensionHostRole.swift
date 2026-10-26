import Foundation

public enum ExtensionHostRole {
    public static var isInterfaceProcess: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }
}
