import Foundation

public enum RGBHex {
    public static func string(red: Int, green: Int, blue: Int, uppercase: Bool = true) -> String {
        let format = uppercase ? "#%02X%02X%02X" : "#%02x%02x%02x"
        return String(format: format, Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    public static func string(
        red: Double, green: Double, blue: Double, uppercase: Bool = true
    ) -> String {
        string(
            red: Int((UnitInterval.clamp(red) * 255).rounded()),
            green: Int((UnitInterval.clamp(green) * 255).rounded()),
            blue: Int((UnitInterval.clamp(blue) * 255).rounded()),
            uppercase: uppercase)
    }

    private static func byte(_ value: Int) -> Int { min(max(value, 0), 255) }
}
