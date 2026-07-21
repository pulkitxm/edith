import AppKit
import SwiftUI

public enum MusicTick {
    public static let epoch = Date(timeIntervalSinceReferenceDate: 0)
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
    private static let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.75, 0.6, 0.9, 0.5]
    private var bars: [CALayer] = []
    private var animating = false
    private var barColor = NSColor.white

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bars.forEach { $0.backgroundColor = barColor.cgColor }
        }
    }

    func apply(playing: Bool, color: NSColor, barCount: Int, maxHeight: CGFloat) {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        barColor = color
        if bars.count != barCount {
            bars.forEach { $0.removeFromSuperlayer() }
            bars = (0..<barCount).map { _ in
                let bar = CALayer()
                bar.cornerRadius = 1.5
                layer?.addSublayer(bar)
                return bar
            }
            animating = false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.backgroundColor = color.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: UIScale.pt(3), height: maxHeight)
            bar.position = CGPoint(x: CGFloat(i) * 5.5 + 1.5, y: maxHeight / 2)
        }
        if playing, !animating {
            for (i, bar) in bars.enumerated() {
                let weight = Self.weights[i % Self.weights.count]
                let scale = CABasicAnimation(keyPath: "transform.scale.y")
                scale.fromValue = 0.3 * weight
                scale.toValue = weight
                scale.duration = 0.45 + Double(i % 3) * 0.18
                scale.autoreverses = true
                scale.repeatCount = .infinity
                scale.timeOffset = Double(i) * 0.13
                scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bar.add(scale, forKey: "wave")
            }
        } else if !playing {
            for bar in bars {
                bar.removeAnimation(forKey: "wave")
                bar.transform = CATransform3DMakeScale(1, 0.15, 1)
            }
        }
        animating = playing
        CATransaction.commit()
    }
}
