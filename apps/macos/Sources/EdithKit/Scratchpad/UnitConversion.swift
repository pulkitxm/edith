enum UnitConversion {
    private static let lengthToMeters: [String: Double] = [
        "m": 1, "meter": 1, "meters": 1,
        "km": 1000, "kilometer": 1000, "kilometers": 1000,
        "cm": 0.01, "centimeter": 0.01, "centimeters": 0.01,
        "mm": 0.001, "millimeter": 0.001, "millimeters": 0.001,
        "mi": 1609.344, "mile": 1609.344, "miles": 1609.344,
        "yd": 0.9144, "yard": 0.9144, "yards": 0.9144,
        "ft": 0.3048, "foot": 0.3048, "feet": 0.3048,
        "in": 0.0254, "inch": 0.0254, "inches": 0.0254,
    ]

    private static let weightToGrams: [String: Double] = [
        "g": 1, "gram": 1, "grams": 1,
        "kg": 1000, "kilogram": 1000, "kilograms": 1000,
        "lb": 453.592, "lbs": 453.592, "pound": 453.592, "pounds": 453.592,
        "oz": 28.3495, "ounce": 28.3495, "ounces": 28.3495,
    ]

    private static let timeToSeconds: [String: Double] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
        "d": 86400, "day": 86400, "days": 86400,
    ]

    static func convert(_ input: String) -> String? {
        let lower = input.lowercased()
        let parts = lower.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }
        guard let value = Double(parts[0]) else { return nil }
        let fromUnit = parts[1]
        guard parts[2] == "to" || parts[2] == "in" || parts[2] == "as" else { return nil }
        let toUnit = parts[3...].joined()

        if (fromUnit == "c" || fromUnit == "f"), (toUnit == "c" || toUnit == "f") {
            return temperature(value: value, from: fromUnit, to: toUnit)
        }
        if let result = convert(value, from: fromUnit, to: toUnit, table: lengthToMeters) {
            return result
        }
        if let result = convert(value, from: fromUnit, to: toUnit, table: weightToGrams) {
            return result
        }
        if let result = convert(value, from: fromUnit, to: toUnit, table: timeToSeconds) {
            return result
        }
        return nil
    }

    private static func convert(
        _ value: Double, from: String, to: String, table: [String: Double]
    ) -> String? {
        guard let fromFactor = table[from], let toFactor = table[to] else { return nil }
        return "\(QuickCalc.format(value * fromFactor / toFactor)) \(to)"
    }

    private static func temperature(value: Double, from: String, to: String) -> String? {
        guard from != to else { return "\(QuickCalc.format(value)) \(to)" }
        if from == "c", to == "f" { return "\(QuickCalc.format(value * 9 / 5 + 32)) f" }
        if from == "f", to == "c" { return "\(QuickCalc.format((value - 32) * 5 / 9)) c" }
        return nil
    }
}
