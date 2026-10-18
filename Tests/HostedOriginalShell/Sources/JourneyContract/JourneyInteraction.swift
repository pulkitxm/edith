import Foundation

public enum JourneyInteraction {
    @MainActor
    public static func waitForCheckboxState(
        _ expected: Int, observations: Int = 51,
        read: () -> Any?,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    ) async throws -> Int {
        guard (0...1).contains(expected), (1...51).contains(observations) else {
            throw JourneyContractError.invalidMetadata
        }
        for observation in 0..<observations {
            try Task.checkCancellation()
            let actual = try checkboxState(read())
            if actual == expected || observation == observations - 1 { return actual }
            try await pause()
        }
        throw JourneyContractError.invalidMetadata
    }

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
