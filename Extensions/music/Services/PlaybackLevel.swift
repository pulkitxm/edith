import EdithExtensionUI
import AppKit
import Combine
import SwiftUI

public enum MeterLevel {
    public static let floorDecibels = -46.0
    public static let ceilingDecibels = -6.0

    public static func gain(appVolume: Double, systemVolume: Double) -> Double {
        let combined = min(max(appVolume, 0), 1) * min(max(systemVolume, 0), 1)
        return combined.squareRoot()
    }

    public static func level(decibels: Double, gain: Double, previous: Double) -> Double {
        let span = ceilingDecibels - floorDecibels
        let loudness = min(max((decibels - floorDecibels) / span, 0), 1)
        return max(loudness * min(max(gain, 0), 1), previous * 0.8)
    }
}

@MainActor
public final class PlaybackLevel: ObservableObject {
    public static let shared = PlaybackLevel()
    public static let neutral = 0.5

    @Published public private(set) var level = PlaybackLevel.neutral
    public private(set) var viewers = 0
    public var onViewersChange: (() -> Void)?

    public func attachViewer() {
        viewers += 1
        if viewers == 1 { onViewersChange?() }
    }

    public func detachViewer() {
        guard viewers > 0 else { return }
        viewers -= 1
        if viewers == 0 { onViewersChange?() }
    }

    public func update(_ value: Double) {
        let next = min(max(value, 0), 1)
        if abs(next - level) > 0.004 { level = next }
    }

    public func reset() {
        if level != Self.neutral { level = Self.neutral }
    }
}
