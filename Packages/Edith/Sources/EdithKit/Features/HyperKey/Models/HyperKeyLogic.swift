import CoreGraphics

public enum HyperKeyLogic {
    public static let capsLockKeyCode: Int64 = 57
    public static let hyperFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
    ]

    public static func isCapsLock(keyCode: Int64) -> Bool {
        keyCode == capsLockKeyCode
    }

    public static func mergedFlags(current: CGEventFlags, hyperActive: Bool) -> CGEventFlags {
        hyperActive ? current.union(hyperFlags) : current
    }
}
