import EdithHostCore
import Foundation

enum UsageLauncherFixture {
    static func capture<Value>(
        extensionID: String, executable: URL, hostIdentifier: String,
        capture: (URL, String) throws -> Value
    ) rethrows -> Value? {
        guard extensionID == "usage" else { return nil }
        return try capture(
            executable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent(), hostIdentifier)
    }

    static func capture(
        extensionID: String, executable: URL, hostIdentifier: String
    ) throws -> HostPublicLauncher? {
        try capture(
            extensionID: extensionID, executable: executable, hostIdentifier: hostIdentifier
        ) { application, identifier in
            try HostPublicLauncher.capture(
                applicationURL: application, hostIdentifier: identifier, teamIdentifier: nil)
        }
    }
}
