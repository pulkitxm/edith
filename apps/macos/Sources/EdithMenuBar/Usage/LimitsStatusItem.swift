import AppKit
import EdithKit

@MainActor
final class LimitsStatusItem {
    nonisolated(unsafe) static private(set) weak var button: NSStatusBarButton?

    private let item: NSStatusItem

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "limits"
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(clicked)
        Self.button = item.button
        showUnavailable()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
        Self.button = nil
    }

    @objc private func clicked() { togglePanel() }

    func update(session: LimitWindow?, week: LimitWindow?) {
        let title = NSMutableAttributedString()
        segment("5h", window: session, kind: .session, into: title)
        title.append(NSAttributedString(string: "  "))
        segment("7d", window: week, kind: .weekly, into: title)
        item.button?.attributedTitle = title
    }

    func showUnavailable() { update(session: nil, week: nil) }

    private func segment(
        _ label: String, window: LimitWindow?, kind: LimitWindowKind,
        into out: NSMutableAttributedString
    ) {
        out.append(
            NSAttributedString(
                string: label + " ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: fixedColor ?? NSColor.secondaryLabelColor,
                    .baselineOffset: 1.5,
                ]))
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        guard let window else {
            out.append(
                NSAttributedString(
                    string: "\u{2013}",
                    attributes: [
                        .font: numberFont,
                        .foregroundColor: fixedColor ?? NSColor.tertiaryLabelColor,
                    ]))
            return
        }
        let tint = fixedColor ?? color(for: window, kind: kind)
        out.append(
            NSAttributedString(
                string: "\(Int(window.percent.rounded()))",
                attributes: [
                    .font: numberFont, .foregroundColor: tint,
                ]))
        out.append(
            NSAttributedString(
                string: "%",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: tint.withAlphaComponent(0.75),
                ]))
    }

    private func color(for window: LimitWindow, kind: LimitWindowKind) -> NSColor {
        let d = SharedDefaults.store
        if d.object(forKey: "smartColor") as? Bool ?? true {
            let risk = LimitMath.smartRisk(
                utilization: window.percent, resetsAt: window.resetsAt,
                windowDuration: kind.duration,
                pacingMargin: d.object(forKey: "pacingMargin") as? Double ?? 10)
            return Self.color(forRisk: risk)
        }
        switch UsageLevel.from(pct: window.percent, thresholds: .fromDefaults(d)) {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        }
    }

    private var fixedColor: NSColor? {
        switch SharedDefaults.store.string(forKey: "menuBarColorMode") {
        case "white": return .white
        case "black": return .black
        default: return nil
        }
    }

    static func color(forRisk risk: Double) -> NSColor {
        let r = max(0, min(1, risk))
        let green = NSColor.systemGreen, orange = NSColor.systemOrange, red = NSColor.systemRed
        if r <= 0.30 { return green }
        if r >= 0.85 { return red }
        if r <= 0.55 { return interpolateHSB(green, orange, t: (r - 0.30) / 0.25) }
        return interpolateHSB(orange, red, t: (r - 0.55) / 0.30)
    }

    private static func interpolateHSB(_ a: NSColor, _ b: NSColor, t: Double) -> NSColor {
        let f = CGFloat(max(0, min(1, t)))
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
        let dh = y.hueComponent - x.hueComponent
        let h: CGFloat
        if abs(dh) <= 0.5 {
            h = (x.hueComponent + dh * f + 1).truncatingRemainder(dividingBy: 1)
        } else if dh > 0.5 {
            h = (x.hueComponent + (dh - 1) * f + 1).truncatingRemainder(dividingBy: 1)
        } else {
            h = (x.hueComponent + (dh + 1) * f + 1).truncatingRemainder(dividingBy: 1)
        }
        return NSColor(
            hue: h,
            saturation: x.saturationComponent + (y.saturationComponent - x.saturationComponent) * f,
            brightness: x.brightnessComponent + (y.brightnessComponent - x.brightnessComponent) * f,
            alpha: 1)
    }
}
