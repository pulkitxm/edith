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
        let data = script.data(using: .utf16LittleEndian) ?? Data()
        return "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass "
            + "-EncodedCommand \(data.base64EncodedString())"
    }

    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
