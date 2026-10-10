import Foundation

public enum ByteFormatter {
    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

}
