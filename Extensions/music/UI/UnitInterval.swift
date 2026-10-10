import Foundation

public enum EmbeddedUnitInterval {
    public static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
