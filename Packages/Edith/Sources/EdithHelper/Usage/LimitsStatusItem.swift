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
        StatusItemMenu.attach(to: item, target: self, action: #selector(clicked))
        Self.button = item.button
        showUnavailable()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
        Self.button = nil
    }

    @objc private func clicked() {
        StatusItemMenu.handleClick(on: item) { MainApp.open(section: "dashboard") }
    }

    func update(_ providers: [ProviderLimits]) {
        let title = NSMutableAttributedString()
        let masked =
            PresenterState.shared.active
            && (SharedDefaults.store.object(forKey: "presenterHideMenuBarNumbers") as? Bool ?? false)
        if providers.count == 1, let limits = providers.first {
            segment("5h", window: limits.session, kind: .session, into: title, masked: masked)
            title.append(NSAttributedString(string: "  "))
            segment("7d", window: limits.week, kind: .weekly, into: title, masked: masked)
        } else if providers.count > 1 {
            for (index, limits) in providers.enumerated() {
                if index > 0 { title.append(NSAttributedString(string: "   ")) }
                providerSegment(limits, into: title, masked: masked)
            }
        } else {
            segment("5h", window: nil, kind: .session, into: title, masked: masked)
            title.append(NSAttributedString(string: "  "))
            segment("7d", window: nil, kind: .weekly, into: title, masked: masked)
        }
        item.button?.attributedTitle = title
    }

    func showUnavailable() { update([]) }

    private func providerSegment(
        _ limits: ProviderLimits, into out: NSMutableAttributedString, masked: Bool
    ) {
        let textColor = subColor ?? numberOverride ?? NSColor.labelColor
        if let image = ProviderLogo.tintedImage(limits.provider, color: textColor) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: " "))
        }
        compactValue(limits.session, kind: .session, into: out, masked: masked)
        out.append(
            NSAttributedString(
                string: "/",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: textColor.withAlphaComponent(0.65),
                ]))
        compactValue(limits.week, kind: .weekly, into: out, masked: masked)
    }

    private func compactValue(
        _ window: LimitWindow?, kind: LimitWindowKind, into out: NSMutableAttributedString,
        masked: Bool
    ) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let text: String
        let color: NSColor
        if masked {
            text = "·"
            color = subColor ?? NSColor.tertiaryLabelColor
        } else if let window {
            text = "\(Int(window.percent.rounded()))"
            color = numberOverride ?? self.color(for: window, kind: kind)
        } else {
            text = "\u{2013}"
            color = subColor ?? NSColor.tertiaryLabelColor
        }
        out.append(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

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
        default:
            return Self.nsColor(hex: SharedDefaults.store.string(forKey: "menuBarSubColorHex"))
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
        guard mode == "custom" || mode == "auto" else { return fallback }
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
