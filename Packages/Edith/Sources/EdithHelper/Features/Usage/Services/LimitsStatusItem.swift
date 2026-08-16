import AppKit
import EdithKit

@MainActor
final class LimitsStatusItem {
    nonisolated(unsafe) static private(set) weak var button: NSStatusBarButton?

    private let item: NSStatusItem
    private var stackedView: StackedLimitsView?

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
        let defaults = SharedDefaults.store
        let masked =
            PresenterState.shared.active
            && (defaults.object(forKey: AppStorageKeys.Presenter.hideMenuBarNumbers)
                as? Bool ?? false)
        let source =
            providers.isEmpty
            ? [ProviderLimits(provider: .claude, session: nil, week: nil)] : providers
        let groups = MenuBarLimits.groups(
            providers: source,
            selection: { MenuBarLimits.selection(for: $0, defaults: defaults) },
            masked: masked)
        item.isVisible = !groups.isEmpty
        guard !groups.isEmpty else { return }
        switch MenuBarLimits.style(defaults) {
        case .stacked: renderStacked(groups)
        case .tagged: renderTagged(groups)
        case .slash: renderSlash(groups)
        }
    }

    func showUnavailable() { update([]) }

    private func setTitle(_ title: NSAttributedString) {
        stackedView?.removeFromSuperview()
        stackedView = nil
        item.length = NSStatusItem.variableLength
        item.button?.attributedTitle = title
    }

    private func renderTagged(_ groups: [MenuBarProviderGroup]) {
        let multi = groups.count > 1
        let title = NSMutableAttributedString()
        for (index, group) in groups.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ")) }
            if multi { appendLogo(group.provider, into: title) }
            for (segmentIndex, segment) in group.segments.enumerated() {
                if segmentIndex > 0 { title.append(NSAttributedString(string: "  ")) }
                appendLabel(segment.slot.menuBarLabel + " ", into: title)
                appendValue(segment, percentSuffix: !multi, into: title)
            }
        }
        setTitle(title)
    }

    private func renderSlash(_ groups: [MenuBarProviderGroup]) {
        let title = NSMutableAttributedString()
        let separatorColor = (subColor ?? numberOverride ?? NSColor.labelColor)
            .withAlphaComponent(0.65)
        for (index, group) in groups.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "   ")) }
            appendLogo(group.provider, into: title)
            for (segmentIndex, segment) in group.segments.enumerated() {
                if segmentIndex > 0 {
                    title.append(
                        NSAttributedString(
                            string: "/",
                            attributes: [
                                .font: NSFont.monospacedDigitSystemFont(
                                    ofSize: 11, weight: .medium),
                                .foregroundColor: separatorColor,
                            ]))
                }
                appendValue(segment, percentSuffix: false, into: title)
            }
        }
        setTitle(title)
    }

    private func renderStacked(_ groups: [MenuBarProviderGroup]) {
        item.button?.attributedTitle = NSAttributedString()
        let view = stackedView ?? StackedLimitsView()
        if stackedView == nil, let button = item.button {
            view.autoresizingMask = [.width, .height]
            view.frame = button.bounds
            button.addSubview(view)
            stackedView = view
        }
        let multi = groups.count > 1
        view.groups = groups.map { stackedGroup($0, multi: multi) }
        item.length = view.desiredWidth
    }

    private func stackedGroup(
        _ group: MenuBarProviderGroup, multi: Bool
    ) -> StackedLimitsView.Group {
        let logoColor = subColor ?? numberOverride ?? NSColor.labelColor
        let labelColor = subColor ?? NSColor.secondaryLabelColor
        let dimColor = subColor ?? NSColor.tertiaryLabelColor
        let columns = group.segments.map { segment -> StackedLimitsView.Column in
            let value: String
            let color: NSColor
            switch segment.value {
            case .masked:
                value = "·"
                color = dimColor
            case .missing:
                value = "\u{2013}"
                color = dimColor
            case .percent(let percent):
                value = "\(percent)"
                color =
                    numberOverride
                    ?? segment.window.map { self.color(for: $0, kind: segment.slot.kind) }
                    ?? dimColor
            }
            return StackedLimitsView.Column(
                label: segment.slot.menuBarLabel, value: value, valueColor: color,
                labelColor: labelColor)
        }
        return StackedLimitsView.Group(
            logo: multi ? ProviderLogo.tintedImage(group.provider, color: logoColor) : nil,
            columns: columns)
    }

    private func appendLogo(_ provider: LimitProvider, into out: NSMutableAttributedString) {
        let textColor = subColor ?? numberOverride ?? NSColor.labelColor
        guard let image = ProviderLogo.tintedImage(provider, color: textColor) else { return }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
        out.append(NSAttributedString(attachment: attachment))
        out.append(NSAttributedString(string: " "))
    }

    private func appendLabel(_ label: String, into out: NSMutableAttributedString) {
        out.append(
            NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: subColor ?? NSColor.secondaryLabelColor,
                    .baselineOffset: 1.5,
                ]))
    }

    private func appendValue(
        _ segment: MenuBarLimitSegment, percentSuffix: Bool, into out: NSMutableAttributedString
    ) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let dimColor = subColor ?? NSColor.tertiaryLabelColor
        switch segment.value {
        case .masked:
            out.append(
                NSAttributedString(
                    string: "·", attributes: [.font: font, .foregroundColor: dimColor]))
        case .missing:
            out.append(
                NSAttributedString(
                    string: "\u{2013}", attributes: [.font: font, .foregroundColor: dimColor]))
        case .percent(let percent):
            let tint =
                numberOverride
                ?? segment.window.map { color(for: $0, kind: segment.slot.kind) }
                ?? dimColor
            out.append(
                NSAttributedString(
                    string: "\(percent)", attributes: [.font: font, .foregroundColor: tint]))
            if percentSuffix {
                out.append(
                    NSAttributedString(
                        string: "%",
                        attributes: [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                            .foregroundColor: tint.withAlphaComponent(0.75),
                        ]))
            }
        }
    }

    private func color(for window: LimitWindow, kind: LimitWindowKind) -> NSColor {
        let d = SharedDefaults.store
        if d.object(forKey: AppStorageKeys.General.smartColor) as? Bool ?? true {
            let risk = LimitMath.smartRisk(
                utilization: window.percent, resetsAt: window.resetsAt,
                windowDuration: kind.duration,
                pacingMargin: d.object(forKey: AppStorageKeys.Limits.pacingMargin) as? Double ?? 10)
            return Self.color(forRisk: risk, low: lowColor, mid: midColor, high: highColor)
        }
        switch UsageLevel.from(pct: window.percent, thresholds: .fromDefaults(d)) {
        case .green: return lowColor
        case .orange: return midColor
        case .red: return highColor
        }
    }

    private var mode: String {
        SharedDefaults.store.string(forKey: AppStorageKeys.MenuBar.colorMode) ?? "auto"
    }

    private var subColor: NSColor? {
        switch mode {
        case "white": return .white
        case "black": return .black
        default:
            return Self.nsColor(
                hex: SharedDefaults.store.string(forKey: AppStorageKeys.MenuBar.subColorHex))
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

    private var lowColor: NSColor { anchor(AppStorageKeys.MenuBar.lowColorHex, .systemGreen) }
    private var midColor: NSColor { anchor(AppStorageKeys.MenuBar.midColorHex, .systemOrange) }
    private var highColor: NSColor { anchor(AppStorageKeys.MenuBar.highColorHex, .systemRed) }

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

final class StackedLimitsView: NSView {
    struct Column {
        let label: String
        let value: String
        let valueColor: NSColor
        let labelColor: NSColor
    }

    struct Group {
        let logo: NSImage?
        let columns: [Column]
    }

    var groups: [Group] = [] {
        didSet { needsDisplay = true }
    }

    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let edgeInset: CGFloat = 5
    private static let columnGap: CGFloat = 7
    private static let groupGap: CGFloat = 12
    private static let logoSize: CGFloat = 12
    private static let logoGap: CGFloat = 4
    private static let rowGap: CGFloat = 1

    var desiredWidth: CGFloat {
        var width = Self.edgeInset * 2
        for (index, group) in groups.enumerated() {
            if index > 0 { width += Self.groupGap }
            if group.logo != nil { width += Self.logoSize + Self.logoGap }
            for (columnIndex, column) in group.columns.enumerated() {
                if columnIndex > 0 { width += Self.columnGap }
                width += Self.columnWidth(column)
            }
        }
        return width.rounded(.up)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelHeight = Self.labelFont.capHeight + 2
        let valueHeight = ceil(Self.valueFont.ascender - Self.valueFont.descender)
        let blockHeight = labelHeight + Self.rowGap + valueHeight
        let blockTop = (bounds.height + blockHeight) / 2
        var x = Self.edgeInset
        for (index, group) in groups.enumerated() {
            if index > 0 { x += Self.groupGap }
            if let logo = group.logo {
                let y = (bounds.height - Self.logoSize) / 2
                logo.draw(
                    in: NSRect(x: x, y: y, width: Self.logoSize, height: Self.logoSize),
                    from: .zero, operation: .sourceOver, fraction: 1)
                x += Self.logoSize + Self.logoGap
            }
            for (columnIndex, column) in group.columns.enumerated() {
                if columnIndex > 0 { x += Self.columnGap }
                let width = Self.columnWidth(column)
                let label = Self.attributed(
                    column.label, font: Self.labelFont, color: column.labelColor)
                let value = Self.attributed(
                    column.value, font: Self.valueFont, color: column.valueColor)
                let labelX = x + (width - label.size().width) / 2
                let valueX = x + (width - value.size().width) / 2
                label.draw(at: NSPoint(x: labelX, y: blockTop - labelHeight))
                value.draw(
                    at: NSPoint(
                        x: valueX, y: blockTop - labelHeight - Self.rowGap - valueHeight))
                x += width
            }
        }
    }

    private static func columnWidth(_ column: Column) -> CGFloat {
        let label = attributed(column.label, font: labelFont, color: .labelColor).size().width
        let value = attributed(column.value, font: valueFont, color: .labelColor).size().width
        return ceil(max(label, value))
    }

    private static func attributed(
        _ text: String, font: NSFont, color: NSColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
    }
}
