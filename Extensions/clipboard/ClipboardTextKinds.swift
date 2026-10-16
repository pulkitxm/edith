import Foundation

public enum ClipboardTextKinds {
    public static let extensions: Set<String> = [
        "txt", "json", "xml", "csv", "tsv", "plist", "yaml", "sql", "sh", "py", "rb",
        "pl", "php", "js", "swift", "md", "log", "conf", "ini", "toml",
    ]

    public static func isText(_ ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }
}
