import Darwin
import Foundation

public enum HostLegacyServices {
    public static let userLabels = ["com.pulkit.edith.agent", "com.pulkit.edith.helper.v2"]

    public static func targets(identity: HostIdentity, user: uid_t = getuid()) -> [String] {
        guard !identity.development else { return [] }
        return userLabels.map { "gui/\(user)/\($0)" }
    }

    public static func retire(
        identity: HostIdentity, user: uid_t = getuid(),
        bootout: (String) -> Void = launchctlBootout
    ) {
        for target in targets(identity: identity, user: user) { bootout(target) }
    }

    public static func launchctlBootout(_ target: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", target]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }
}
