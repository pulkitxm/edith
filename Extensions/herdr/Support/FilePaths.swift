import Foundation

public enum FileListing {
    public static func join(parent: String, name: String) -> String {
        if isWindowsPath(parent) {
            return parent.hasSuffix("\\") ? parent + name : parent + "\\" + name
        }
        if parent == "/" { return "/" + name }
        return parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    public static func parentPath(of path: String) -> String? {
        if isWindowsPath(path) {
            let normalized = path.hasSuffix("\\") ? String(path.dropLast()) : path
            guard let slash = normalized.lastIndex(of: "\\") else { return nil }
            let parent = String(normalized[..<slash])
            if parent.count == 2, parent.last == ":" { return parent + "\\" }
            return parent.isEmpty ? nil : parent
        }
        guard path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    public static func name(of path: String) -> String {
        if isWindowsPath(path) {
            let normalized = path.hasSuffix("\\") ? String(path.dropLast()) : path
            return normalized.split(separator: "\\").last.map(String.init) ?? normalized
        }
        return (path as NSString).lastPathComponent
    }

    public static func isWindowsPath(_ path: String) -> Bool {
        path.range(of: "^[A-Za-z]:\\\\", options: .regularExpression) != nil
            || path.hasPrefix("\\\\") || path.hasPrefix("~\\")
    }
}
public enum FilePlaces {
    public static func homeDirectoryCommand(platform: RemoteMachinePlatform) -> String {
        platform == .windows
            ? PowerShell.command("[Console]::Out.Write($env:USERPROFILE)") : "printf '%s' \"$HOME\""
    }
}
