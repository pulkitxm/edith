import CoreGraphics
import Foundation

public enum MouseButtonAction: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case passThrough
    case back
    case forward
    case middleClick
    case closeTab
    case reopenTab
    case missionControl
    case appExpose
    case showDesktop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .passThrough: "Leave unchanged"
        case .back: "Back"
        case .forward: "Forward"
        case .middleClick: "Middle click"
        case .closeTab: "Close tab"
        case .reopenTab: "Reopen tab"
        case .missionControl: "Mission Control"
        case .appExpose: "Application windows"
        case .showDesktop: "Show Desktop"
        }
    }
}

public enum MouseControlSupport {
    public static let buttonNumbers = 3...7
    public static let scrollStepRange = 20...100
    public static let defaultScrollStep = 40
    public static let focusDelayRange = 100...1_000
    public static let defaultFocusDelay = 300
    public static let syntheticEventTag: Int64 = 0x45444954484D4F55

    public static func sanitizedScrollStep(_ value: Int) -> Int {
        guard value != 0 else { return defaultScrollStep }
        return min(max(value, scrollStepRange.lowerBound), scrollStepRange.upperBound)
    }

    public static func sanitizedFocusDelay(_ value: Int) -> Int {
        guard value != 0 else { return defaultFocusDelay }
        return min(max(value, focusDelayRange.lowerBound), focusDelayRange.upperBound)
    }

    public static func ticks(integer: Double, fixedPoint: Double) -> Double {
        fixedPoint == 0 ? integer : fixedPoint
    }

    public static func axes(
        vertical: Double, horizontal: Double, shiftPressed: Bool,
        reverseVertical: Bool, reverseHorizontal: Bool
    ) -> (vertical: Double, horizontal: Double) {
        let shifted = shiftPressed && horizontal == 0
        let rawVertical = shifted ? 0 : vertical
        let rawHorizontal = shifted ? vertical : horizontal
        return (
            rawVertical * (reverseVertical ? -1 : 1),
            rawHorizontal * (reverseHorizontal ? -1 : 1)
        )
    }

    public static func nextRemaining(current: Double, added: Double) -> Double {
        guard current != 0, added != 0, (current < 0) != (added < 0) else {
            return current + added
        }
        return added
    }

    public static func frameDelta(_ remaining: Double) -> Double {
        guard abs(remaining) > 1 else { return remaining }
        return (remaining < 0 ? -1 : 1) * max(abs(remaining) * 0.2, 1)
    }

    public static func resolvedAction(
        buttonNumber: Int, stored: String?, sideNavigation: Bool
    ) -> MouseButtonAction {
        let fallback: MouseButtonAction = buttonNumber <= 4 ? .automatic : .passThrough
        let action = stored.flatMap(MouseButtonAction.init(rawValue:)) ?? fallback
        guard action == .automatic else { return action }
        guard sideNavigation else { return .passThrough }
        if buttonNumber == 3 { return .back }
        if buttonNumber == 4 { return .forward }
        return .passThrough
    }

    public static func excludedBundleIDs(_ raw: String?) -> Set<String> {
        Set(
            (raw ?? "").split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
    }

    public static func isExcluded(_ bundleIdentifier: String?, from exclusions: Set<String>) -> Bool
    {
        guard let bundleIdentifier else { return false }
        return exclusions.contains(bundleIdentifier.lowercased())
    }
}
