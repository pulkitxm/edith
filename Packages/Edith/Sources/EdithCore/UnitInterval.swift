import Foundation

public enum UnitInterval {
    public static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
