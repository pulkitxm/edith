import Foundation

enum DoubleQuoted {
    static func wrap(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
