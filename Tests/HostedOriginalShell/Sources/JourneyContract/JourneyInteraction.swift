import Foundation

public enum JourneyInteraction {
    public static func checkboxState(_ value: Any?) throws -> Int {
        if let value = value as? String, value == "0" || value == "1", let state = Int(value) {
            return state
        }
        if let value = value as? NSNumber, value.doubleValue.isFinite {
            if value == NSNumber(value: 0) { return 0 }
            if value == NSNumber(value: 1) { return 1 }
        }
        throw JourneyContractError.invalidMetadata
    }

    public static func checkboxValueCategory(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        return "unsupported"
    }
}
