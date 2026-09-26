import Foundation

public enum DoubleQuoted {
    public static func wrap(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
