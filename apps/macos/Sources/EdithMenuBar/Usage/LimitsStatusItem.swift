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
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        Self.button = item.button
        showUnavailable()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
        Self.button = nil
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            StatusItemMenu.show(from: item)
        } else {
            MainApp.openDashboard()
        }
    }

    func update(session: LimitWindow?, week: LimitWindow?) {
        let title = NSMutableAttributedString()
        let masked =
            PresenterState.shared.active
            && (SharedDefaults.store.object(forKey: "presenterHideMenuBarNumbers") as? Bool ?? false)
        segment("5h", window: session, kind: .session, into: title, masked: masked)
        title.append(NSAttributedString(string: "  "))
        segment("7d", window: week, kind: .weekly, into: title, masked: masked)
        item.button?.attributedTitle = title
    }

    func showUnavailable() { update(session: nil, week: nil) }

    private func segment(
        _ label: String, window: LimitWindow?, kind: LimitWindowKind,
        into out: NSMutableAttributedString, masked: Bool
    ) {
        out.append(
            NSAttributedString(
                string: label + " ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: subColor ?? NSColor.secondaryLabelColor,
                    .baselineOffset: 1.5,
                ]))
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        guard !masked else {
            out.append(
                NSAttributedString(
                    string: "· ·",
                    attributes: [
                        .font: numberFont,
                        .foregroundColor: subColor ?? NSColor.tertiaryLabelColor,
                    ]))
            return
        }
        guard let window else {
            out.append(
                NSAttributedString(
                    string: "\u{2013}",
                    attributes: [
                        .font: numberFont,
                        .foregroundColor: subColor ?? NSColor.tertiaryLabelColor,
                    ]))
            return
        }
        let tint = numberOverride ?? color(for: window, kind: kind)
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
            return Self.color(forRisk: risk, low: lowColor, mid: midColor, high: highColor)
        }
        switch UsageLevel.from(pct: window.percent, thresholds: .fromDefaults(d)) {
        case .green: return lowColor
        case .orange: return midColor
        case .red: return highColor
        }
    }

    private var mode: String { SharedDefaults.store.string(forKey: "menuBarColorMode") ?? "auto" }

    private var subColor: NSColor? {
        switch mode {
        case "white": return .white
        case "black": return .black
        case "custom":
            return Self.nsColor(hex: SharedDefaults.store.string(forKey: "menuBarSubColorHex"))
        default: return nil
        }
    }

    private var numberOverride: NSColor? {
        switch mode {
        case "white": return .white
        case "black": return .black
        default: return nil
        }
    }

    private func anchor(_ key: String, _ fallback: NSColor) -> NSColor {
        guard mode == "custom" else { return fallback }
        return Self.nsColor(hex: SharedDefaults.store.string(forKey: key)) ?? fallback
    }

    private var lowColor: NSColor { anchor("menuBarLowColorHex", .systemGreen) }
    private var midColor: NSColor { anchor("menuBarMidColorHex", .systemOrange) }
    private var highColor: NSColor { anchor("menuBarHighColorHex", .systemRed) }

    static func color(
        forRisk risk: Double, low: NSColor = .systemGreen, mid: NSColor = .systemOrange,
        high: NSColor = .systemRed
    ) -> NSColor {
        let r = max(0, min(1, risk))
        if r <= 0.30 { return low }
        if r >= 0.85 { return high }
        if r <= 0.55 { return interpolateHSB(low, mid, t: (r - 0.30) / 0.25) }
        return interpolateHSB(mid, high, t: (r - 0.55) / 0.30)
    }

    static func nsColor(hex: String?) -> NSColor? {
        guard var s = hex else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
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
