import Foundation

public enum BacktickQuoted {
    public static func wrap(_ value: String) -> String {
        "`" + value.replacingOccurrences(of: "`", with: "``") + "`"
    }
}
