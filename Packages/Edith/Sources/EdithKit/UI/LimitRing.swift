import SwiftUI

public enum LimitRing {
    public static let okColor = Color(red: 0x6a / 255, green: 0x8d / 255, blue: 0x73 / 255)
    public static let warnColor = Color.orange
    public static let criticalColor = Color.red

    public static let defaultWarnPercent = 60
    public static let defaultCriticalPercent = 85

    public static func color(percent: Double, warn: Int, critical: Int) -> Color {
        if percent >= Double(critical) { return criticalColor }
        if percent >= Double(warn) { return warnColor }
        return okColor
    }

    public static func animation(reduceMotion: Bool) -> Animation {
        Motion.animation(Motion.settle, reduceMotion: reduceMotion)
    }
}
