import CoreGraphics
import Foundation

public enum FocusDimMath {
    public static let intensityRange: ClosedRange<Double> = 0...0.9
    public static let defaultIntensity = 0.45
    public static let animationDurationRange: ClosedRange<Double> = 0.05...1.0
    public static let defaultAnimationDuration = 0.25

    public static func clampIntensity(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultIntensity }
        return min(max(value, intensityRange.lowerBound), intensityRange.upperBound)
    }

    public static func clampAnimationDuration(_ value: Double) -> Double {
        guard !value.isNaN else { return defaultAnimationDuration }
        return min(
            max(value, animationDurationRange.lowerBound), animationDurationRange.upperBound)
    }
}

public enum FocusDimDisplayMode: String, CaseIterable {
    case perScreenFront
    case dimUnfocused

    public static func from(_ raw: String?) -> FocusDimDisplayMode {
        raw.flatMap(FocusDimDisplayMode.init(rawValue:)) ?? .perScreenFront
    }
}

public struct FocusDimWindowInfo: Equatable {
    public let windowNumber: Int
    public let ownerPID: pid_t
    public let frame: CGRect

    public init(windowNumber: Int, ownerPID: pid_t, frame: CGRect) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.frame = frame
    }
}

public enum FocusDimSelection {
    public static func referenceWindow(
        forScreen screenFrame: CGRect,
        frontmostPID: pid_t,
        windowsFrontToBack: [FocusDimWindowInfo],
        mode: FocusDimDisplayMode
    ) -> FocusDimWindowInfo? {
        switch mode {
        case .dimUnfocused:
            guard
                let frontWindow = windowsFrontToBack.first(where: {
                    $0.ownerPID == frontmostPID
                }),
                screenFrame.contains(CGPoint(x: frontWindow.frame.midX, y: frontWindow.frame.midY))
            else { return nil }
            return windowsFrontToBack.last(where: { $0.ownerPID == frontmostPID })
        case .perScreenFront:
            guard
                let topWindowHere = windowsFrontToBack.first(where: {
                    screenFrame.intersects($0.frame)
                })
            else { return nil }
            return windowsFrontToBack.last(where: { $0.ownerPID == topWindowHere.ownerPID })
        }
    }
}
