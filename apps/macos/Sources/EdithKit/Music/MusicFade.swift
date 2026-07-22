import Foundation

public enum MusicFade {
    public static let enabledKey = "musicCrossfadeEnabled"
    public static let secondsKey = "musicCrossfadeSeconds"
    public static let defaultSeconds: Double = 2
    public static let secondsRange: ClosedRange<Double> = 0.5...8

    public static func clamp(_ seconds: Double) -> Double {
        min(max(seconds, secondsRange.lowerBound), secondsRange.upperBound)
    }

    public static func duration(from defaults: UserDefaults) -> TimeInterval {
        guard defaults.bool(forKey: enabledKey) else { return 0 }
        let stored = defaults.double(forKey: secondsKey)
        return clamp(stored > 0 ? stored : defaultSeconds)
    }
}
