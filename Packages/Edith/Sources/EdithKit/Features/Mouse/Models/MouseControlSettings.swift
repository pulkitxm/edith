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
    public struct ScrollTraits: Equatable, Sendable {
        public let isContinuous: Bool
        public let momentumPhase: Int64
        public let scrollPhase: Int64
        public let scrollCount: Int64

        public init(
            isContinuous: Bool, momentumPhase: Int64, scrollPhase: Int64, scrollCount: Int64
        ) {
            self.isContinuous = isContinuous
            self.momentumPhase = momentumPhase
            self.scrollPhase = scrollPhase
            self.scrollCount = scrollCount
        }
    }

    public enum MiddleClickDecision: Equatable, Sendable {
        case transform
        case passThrough
        case suppress
    }

    public static let buttonNumbers = 3...7
    public static let scrollStepRange = 20...100
    public static let defaultScrollStep = 40
    public static let focusDelayRange = 100...1_000
    public static let defaultFocusDelay = 300
    public static let syntheticEventTag: Int64 = 0x45444954484D4F55
    public static let touchGestureGrace: TimeInterval = 1
    public static let middleClickFrameFreshness: TimeInterval = 0.25
    public static let middleClickMinimumSettle: TimeInterval = 0.04
    public static let middleClickRepeatGuard: TimeInterval = 0.3

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

    public static func isMouseWheel(
        _ traits: ScrollTraits, secondsSinceLastGesturePhase: TimeInterval?
    ) -> Bool {
        if !traits.isContinuous { return true }
        guard traits.momentumPhase == 0, traits.scrollPhase == 0 else { return false }
        if traits.scrollCount != 0, let elapsed = secondsSinceLastGesturePhase,
            elapsed <= touchGestureGrace
        {
            return false
        }
        return true
    }

    public static func continuousDistance(
        fixedPoint: Double, point: Double, step: Double
    ) -> Double {
        guard fixedPoint.isFinite, point.isFinite, step.isFinite else { return 0 }
        let pixels = point != 0 ? point : fixedPoint * 10
        return pixels * step / Double(defaultScrollStep)
    }

    public static func wholePixels(
        _ distance: Double, carry: Double
    ) -> (pixels: Double, carry: Double) {
        let total = distance + carry
        guard total.isFinite else { return (0, 0) }
        let whole = total.rounded(.towardZero)
        return (whole, total - whole)
    }

    public static func finalPixels(_ distance: Double, carry: Double) -> Double {
        let total = distance + carry
        guard total.isFinite else { return 0 }
        return total.rounded(.toNearestOrAwayFromZero)
    }

    public static func continuingCarry(_ carry: Double, distance: Double) -> Double {
        guard carry != 0, distance != 0, (carry < 0) != (distance < 0) else { return carry }
        return 0
    }

    public static func middleClickDecision(
        fingerCount: Int, frameAge: TimeInterval, settledFor: TimeInterval,
        sinceLastTransform: TimeInterval?, systemDragEnabled: Bool
    ) -> MiddleClickDecision {
        guard !systemDragEnabled, fingerCount == 3, frameAge >= 0,
            frameAge <= middleClickFrameFreshness
        else { return .passThrough }
        if let sinceLastTransform, sinceLastTransform >= 0,
            sinceLastTransform < middleClickRepeatGuard
        {
            return .suppress
        }
        guard settledFor >= middleClickMinimumSettle else { return .passThrough }
        return .transform
    }

    public static func systemThreeFingerDragEnabled() -> Bool {
        boolPreference(
            "TrackpadThreeFingerDrag", domain: "com.apple.AppleMultitouchTrackpad")
            || boolPreference(
                "TrackpadThreeFingerDrag",
                domain: "com.apple.driver.AppleBluetoothMultitouch.trackpad")
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

    private static func boolPreference(_ key: String, domain: String) -> Bool {
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
