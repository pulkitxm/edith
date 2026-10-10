import Foundation

public enum JourneyInteraction {
    public static func checkboxState(_ value: Any?) throws -> Int {
        let text: String
        if let value = value as? String {
            text = value
        } else if let value = value as? NSNumber {
            text = value.stringValue
        } else {
            throw JourneyContractError.invalidMetadata
        }
        guard text == "0" || text == "1", let state = Int(text) else {
            throw JourneyContractError.invalidMetadata
        }
        return state
    }

    public static func checkboxValueCategory(_ value: Any?) -> String {
        guard let value else { return "absent" }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        return "unsupported"
    }
}
