import Foundation

public enum LidAwakeCommand {
    public static let toolPath = "/usr/bin/pmset"

    public static func arguments(active: Bool) -> [String] {
        ["-a", "disablesleep", active ? "1" : "0"]
    }

    public static func shellCommand(active: Bool) -> String {
        ([toolPath] + arguments(active: active)).joined(separator: " ")
    }

    public static func sleepDisabled(inPowerSettings output: String) -> Bool {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            return fields[1] == "1"
        }
        return false
    }
}

@objc public protocol LidAwakePrivilegedProtocol {
    func setSleepDisabled(_ disable: Bool, reply: @escaping (NSError?) -> Void)
}
