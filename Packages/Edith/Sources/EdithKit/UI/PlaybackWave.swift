import AppKit
import Combine
import SwiftUI

public enum MusicTick {
    public static let epoch = Date(timeIntervalSinceReferenceDate: 0)
}

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

    public func update(_ value: Double) {
        let next = min(max(value, 0), 1)
        if abs(next - level) > 0.004 { level = next }
    }

    public func reset() {
        if level != Self.neutral { level = Self.neutral }
    }
}

public struct PlaybackWave: View {
    let playing: Bool
    let color: Color
    var barCount: Int
    var maxHeight: CGFloat

    public init(playing: Bool, color: Color, barCount: Int = 5, maxHeight: CGFloat = 18) {
        self.playing = playing
        self.color = color
        self.barCount = barCount
        self.maxHeight = maxHeight
    }

    public var body: some View {
        WaveLayers(playing: playing, color: color, barCount: barCount, maxHeight: maxHeight)
            .frame(
                width: CGFloat(barCount) * 3 + CGFloat(barCount - 1) * 2.5, height: maxHeight)
    }
}

private struct WaveLayers: NSViewRepresentable {
    let playing: Bool
    let color: Color
    let barCount: Int
    let maxHeight: CGFloat

    func makeNSView(context: Context) -> WaveBarsView {
        WaveBarsView()
    }

    func updateNSView(_ view: WaveBarsView, context: Context) {
        view.apply(
            playing: playing, color: NSColor(color), barCount: barCount, maxHeight: maxHeight)
    }
}

private final class WaveBarsView: NSView {
    private let container = CALayer()
    private var bars: [CALayer] = []
    private var animating = false
    private var barColor = NSColor.white
    private var level = CGFloat(PlaybackLevel.neutral)
    private var levelObserver: AnyCancellable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(container)
        levelObserver = PlaybackLevel.shared.$level.sink { [weak self] value in
            MainActor.assumeIsolated { self?.setLevel(CGFloat(value)) }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bars.forEach { $0.backgroundColor = barColor.cgColor }
        }
    }

    func apply(playing: Bool, color: NSColor, barCount: Int, maxHeight: CGFloat) {
        barColor = color
        if bars.count != barCount {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                bar.cornerRadius = 1.5
                container.addSublayer(bar)
                return bar
            }
            animating = false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(
            x: 0, y: 0, width: CGFloat(barCount) * 5.5, height: maxHeight)
        container.position = CGPoint(x: CGFloat(barCount) * 2.75, y: maxHeight / 2)
        for (i, bar) in bars.enumerated() {
            bar.backgroundColor = color.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: UIScale.pt(3), height: maxHeight)
            bar.position = CGPoint(x: CGFloat(i) * 5.5 + 1.5, y: maxHeight / 2)
        }
        if playing == animating {
            container.transform = CATransform3DMakeScale(1, playing ? envelope : Self.resting, 1)
        }
        CATransaction.commit()
        guard playing != animating else { return }
        animating = playing
        playing ? startWave() : settleWave()
    }

    private static let resting: CGFloat = 0.15
    private static let transition = 0.4

    private var envelope: CGFloat { 0.28 + 0.72 * level }

    private func startWave() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.transition)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for bar in bars {
            bar.removeAnimation(forKey: "settle")
            bar.add(Self.texture(), forKey: "wave")
        }
        container.transform = CATransform3DMakeScale(1, envelope, 1)
        CATransaction.commit()
    }

    private func settleWave() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.transition)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for bar in bars {
            let held =
                bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.removeAnimation(forKey: "wave")
            bar.transform = CATransform3DIdentity
            CATransaction.commit()
            let settle = CABasicAnimation(keyPath: "transform.scale.y")
            settle.fromValue = held
            settle.toValue = 1
            settle.duration = Self.transition
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(settle, forKey: "settle")
        }
        container.transform = CATransform3DMakeScale(1, Self.resting, 1)
        CATransaction.commit()
    }

    private func setLevel(_ value: CGFloat) {
        level = value
        guard animating else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        container.transform = CATransform3DMakeScale(1, envelope, 1)
        CATransaction.commit()
    }

    private static func texture() -> CAKeyframeAnimation {
        var values = (0..<12).map { _ in CGFloat.random(in: 0.25...1) }
        values.append(values[0])
        let wave = CAKeyframeAnimation(keyPath: "transform.scale.y")
        wave.values = values
        wave.duration = Double.random(in: 2.6...4.4)
        wave.calculationMode = .cubic
        wave.repeatCount = .infinity
        wave.timeOffset = Double.random(in: 0...2.5)
        return wave
    }
}
