import AppKit
import EdithKit

@MainActor
final class LimitsStatusItem {
    nonisolated(unsafe) static private(set) weak var button: NSStatusBarButton?

    private var item: NSStatusItem?
    private var stackedView: StackedLimitsView?

    init() {
        showUnavailable()
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        stackedView = nil
        Self.button = nil
    }

    @objc private func clicked() {
        guard let item else { return }
        StatusItemMenu.handleClick(on: item) { MainApp.open(section: "dashboard") }
    }

    func update(_ providers: [ProviderLimits]) {
        let defaults = SharedDefaults.store
        let masked =
            PresenterState.shared.active
            && (defaults.object(forKey: AppStorageKeys.Presenter.hideMenuBarNumbers)
                as? Bool ?? false)
        let source = Self.stableProviders(providers, defaults: defaults)
        let groups = MenuBarLimits.groups(
            providers: source,
            selection: { MenuBarLimits.selection(for: $0, defaults: defaults) },
            masked: masked)
        guard !groups.isEmpty else {
            item?.isVisible = false
            return
        }
        switch MenuBarLimits.style(defaults) {
        case .stacked: renderStacked(groups)
        case .tagged: renderTagged(groups)
        case .slash: renderSlash(groups)
        }
        item?.isVisible = true
    }

    func showUnavailable() { update([]) }

    private func setTitle(
        _ title: NSAttributedString, sizingTitle: NSAttributedString
    ) {
        ensureStatusItem(length: StatusItemSizing.titleLength(sizingTitle))
        stackedView?.removeFromSuperview()
        stackedView = nil
        item?.button?.attributedTitle = title
    }

    private func renderTagged(_ groups: [MenuBarProviderGroup]) {
        setTitle(taggedTitle(groups), sizingTitle: taggedTitle(Self.sizingGroups(groups)))
    }

    private func taggedTitle(_ groups: [MenuBarProviderGroup]) -> NSAttributedString {
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
        return title
    }

    private func renderSlash(_ groups: [MenuBarProviderGroup]) {
        setTitle(slashTitle(groups), sizingTitle: slashTitle(Self.sizingGroups(groups)))
    }

    private func slashTitle(_ groups: [MenuBarProviderGroup]) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let separatorColor = (subColor ?? NSColor.labelColor)
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
        return title
    }

    private func renderStacked(_ groups: [MenuBarProviderGroup]) {
        let sizingView = StackedLimitsView()
        sizingView.groups = stackedGroups(Self.sizingGroups(groups))
        ensureStatusItem(length: sizingView.desiredWidth)
        item?.button?.attributedTitle = NSAttributedString()
        let view = stackedView ?? StackedLimitsView()
        if stackedView == nil, let button = item?.button {
            view.autoresizingMask = [.width, .height]
            view.frame = button.bounds
            button.addSubview(view)
            stackedView = view
        }
        view.groups = stackedGroups(groups)
    }

    private func ensureStatusItem(length: CGFloat) {
        if let item, abs(item.length - length) < 0.5 { return }
        if let item { NSStatusBar.system.removeStatusItem(item) }
        stackedView = nil
        let next = NSStatusBar.system.statusItem(withLength: length)
        next.autosaveName = "agentUsage.v2"
        next.isVisible = true
        StatusItemMenu.attach(to: next, target: self, action: #selector(clicked))
        item = next
        Self.button = next.button
    }

    static func stableProviders(
        _ providers: [ProviderLimits], defaults: UserDefaults
    ) -> [ProviderLimits] {
        var available: [LimitProvider: ProviderLimits] = [:]
        for provider in providers.prefix(LimitProvider.allCases.count) {
            available[provider.provider] = provider
        }
        let enabled = UsageStore.enabledLimitProviders(
            claude: defaults.object(forKey: AppStorageKeys.Limits.claudeEnabled) as? Bool ?? true,
            codex: defaults.object(forKey: AppStorageKeys.Limits.codexEnabled) as? Bool ?? true)
        var stable: [ProviderLimits] = []
        stable.reserveCapacity(enabled.count)
        for provider in enabled.prefix(LimitProvider.allCases.count) {
            stable.append(
                available[provider]
                    ?? ProviderLimits(provider: provider, session: nil, week: nil))
        }
        return stable
    }

    static func sizingGroups(_ groups: [MenuBarProviderGroup]) -> [MenuBarProviderGroup] {
        var sizing: [MenuBarProviderGroup] = []
        sizing.reserveCapacity(groups.count)
        for group in groups.prefix(LimitProvider.allCases.count) {
            var segments: [MenuBarLimitSegment] = []
            segments.reserveCapacity(group.segments.count)
            for segment in group.segments.prefix(LimitWindowSlot.allCases.count) {
                segments.append(
                    MenuBarLimitSegment(slot: segment.slot, value: .percent(100), window: nil))
            }
            sizing.append(MenuBarProviderGroup(provider: group.provider, segments: segments))
        }
        return sizing
    }

    private func stackedGroups(_ groups: [MenuBarProviderGroup]) -> [StackedLimitsView.Group] {
        let multi = groups.count > 1
        return groups.map { stackedGroup($0, multi: multi) }
    }

    private func stackedGroup(
        _ group: MenuBarProviderGroup, multi: Bool
    ) -> StackedLimitsView.Group {
        let logoColor = subColor ?? NSColor.labelColor
        let labelColor = subColor ?? NSColor.secondaryLabelColor
        let dimColor = subColor ?? NSColor.tertiaryLabelColor
        var columns: [StackedLimitsView.Column] = []
        columns.reserveCapacity(group.segments.count)
        for segment in group.segments {
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
                    segment.window.map { self.color(for: $0, kind: segment.slot.kind) }
                    ?? dimColor
            }
            columns.append(
                StackedLimitsView.Column(
                    label: segment.slot.menuBarLabel, value: value, valueColor: color,
                    labelColor: labelColor))
        }
        return StackedLimitsView.Group(
            logo: multi ? ProviderLogo.tintedImage(group.provider, color: logoColor) : nil,
            columns: columns)
    }

    private func appendLogo(_ provider: LimitProvider, into out: NSMutableAttributedString) {
        let textColor = subColor ?? NSColor.labelColor
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
                segment.window.map { color(for: $0, kind: segment.slot.kind) }
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

    private var mode: MenuBarTintMode {
        MenuBarTintMode(
            preference: SharedDefaults.store.string(forKey: AppStorageKeys.MenuBar.colorMode))
    }

    private var subColor: NSColor? {
        switch mode {
        case .automatic:
            return nil
        case .custom:
            return Self.nsColor(
                hex: SharedDefaults.store.string(forKey: AppStorageKeys.MenuBar.subColorHex))
        }
    }

    private func anchor(_ key: String, _ fallback: NSColor) -> NSColor {
        guard mode == .custom else { return fallback }
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
