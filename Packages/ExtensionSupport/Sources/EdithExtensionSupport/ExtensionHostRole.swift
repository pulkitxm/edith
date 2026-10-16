import Foundation

public enum ExtensionHostRole {
    private static let state = ExtensionHostRoleState()

    public static var isInterfaceProcess: Bool {
        state.rendersInHost || Bundle.main.bundleURL.pathExtension == "appex"
    }

    static func markRendersInHost() { state.rendersInHost = true }
}

private final class ExtensionHostRoleState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var rendersInHost: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
