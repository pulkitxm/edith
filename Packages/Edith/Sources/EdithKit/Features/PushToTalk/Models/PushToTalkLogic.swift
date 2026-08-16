import CoreGraphics

public enum PushToTalkLogic {
    private static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl,
    ]

    public static func matches(
        keyCode: Int64, flags: CGEventFlags, targetKeyCode: Int64, targetFlags: CGEventFlags
    ) -> Bool {
        guard keyCode == targetKeyCode else { return false }
        return flags.intersection(relevantFlags) == targetFlags.intersection(relevantFlags)
    }
}
