import Foundation

public enum RemoteMachinePlatform: String, Codable, Equatable, Sendable {
    case darwin
    case linux
    case windows

    public static func unixName(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Darwin": .darwin
        case "Linux": .linux
        default: nil
        }
    }

    public static func windowsName(_ value: String) -> Self? {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == "Windows_NT"
            ? .windows : nil
    }
}

public enum PowerShell {
    public static func command(_ script: String) -> String {
        executable(arguments: ["-NonInteractive"], script: script)
    }

    public static func interactiveCommand(_ script: String, keepOpen: Bool = false) -> String {
        executable(arguments: keepOpen ? ["-NoExit"] : [], script: script)
    }

    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func invocation(_ words: [String]) -> String? {
        guard let first = words.first else { return nil }
        guard words.count > 1 else { return first }
        return "& " + words.map(literal).joined(separator: " ")
    }

    private static func executable(arguments: [String], script: String) -> String {
        let data = script.data(using: .utf16LittleEndian) ?? Data()
        let options = (["-NoLogo", "-NoProfile"] + arguments + ["-ExecutionPolicy", "Bypass"])
            .joined(separator: " ")
        return "powershell.exe \(options) -EncodedCommand \(data.base64EncodedString())"
    }
}
