import EdithIcons
import EdithExtensionCore
import SwiftUI

public struct PageCapsLabel: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text).pageCapsStyle()
    }
}

private struct PageCapsStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .font(PageMetrics.capsFont)
            .tracking(UIScale.pt(0.8))
            .textCase(.uppercase)
            .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            .lineLimit(1)
    }
}

extension View {
    public func pageCapsStyle() -> some View {
        modifier(PageCapsStyle())
    }

    public func pageChipChrome(active: Bool = false, tint: Color? = nil) -> some View {
        modifier(PageChipChrome(active: active, tint: tint, pressed: false, iconOnly: false))
    }
}

public struct PageChipLabel: View {
    let title: String
    var icon: EdithIcon?
    var dot: Color?
    var menu = false

    public init(_ title: String, icon: EdithIcon? = nil, dot: Color? = nil, menu: Bool = false) {
        self.title = title
        self.icon = icon
        self.dot = dot
        self.menu = menu
    }

    public var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            if let dot {
                Circle().fill(dot)
                    .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                    .accessibilityHidden(true)
            } else if let icon {
                EdithIconView(icon)
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(title).lineLimit(1)
            if menu {
                EdithIconView(.chevronDown)
                    .font(.system(size: UIScale.pt(8), weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct PageChipChrome: ViewModifier {
    let active: Bool
    let tint: Color?
    let pressed: Bool
    let iconOnly: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let accent = tint ?? DashSkin.accent(dark)
        let shape = RoundedRectangle(
            cornerRadius: UIScale.pt(PageMetrics.chipCornerRadius), style: .continuous)
        content
            .font(PageMetrics.chipFont)
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.horizontal, iconOnly ? 0 : UIScale.pt(10))
            .frame(
                minWidth: iconOnly ? UIScale.pt(PageMetrics.chipHeight) : nil,
                minHeight: UIScale.pt(PageMetrics.chipHeight)
            )
            .background {
                shape.fill(
                    active
                        ? AnyShapeStyle(accent.opacity(dark ? 0.24 : 0.14))
                        : AnyShapeStyle(DashSkin.paper2(dark)))
                if hovering || pressed {
                    shape.fill(Color.primary.opacity(pressed ? 0.1 : 0.05))
                }
            }
            .overlay {
                shape.strokeBorder(
                    focused ? accent : active ? accent.opacity(0.6) : DashSkin.lineStrong(dark),
                    lineWidth: focused ? 2 : contrast == .increased ? 1 : UIScale.pt(0.75))
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovering = enabled && $0 }
            .animation(
                Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: hovering
            )
            .accessibilityAddTraits(active ? .isSelected : AccessibilityTraits())
    }
}

public struct PageChipStyle: ButtonStyle {
    public let active: Bool
    public let tint: Color?
    public let iconOnly: Bool

    public init(active: Bool = false, tint: Color? = nil, iconOnly: Bool = false) {
        self.active = active
        self.tint = tint
        self.iconOnly = iconOnly
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(
                PageChipChrome(
                    active: active, tint: tint, pressed: configuration.isPressed,
                    iconOnly: iconOnly))
    }
}

extension ButtonStyle where Self == PageChipStyle {
    public static func pageChip(
        active: Bool = false, tint: Color? = nil, iconOnly: Bool = false
    ) -> PageChipStyle {
        PageChipStyle(active: active, tint: tint, iconOnly: iconOnly)
    }
}

public struct PageChip: View {
    let title: String
    var icon: EdithIcon?
    var dot: Color?
    var active = false
    var tint: Color?
    let action: () -> Void

    public init(
        _ title: String, icon: EdithIcon? = nil, dot: Color? = nil, active: Bool = false,
        tint: Color? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.dot = dot
        self.active = active
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            PageChipLabel(title, icon: icon, dot: dot)
        }
        .buttonStyle(.pageChip(active: active, tint: tint))
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : AccessibilityTraits())
    }
}

public struct PageIconChip: View {
    let icon: EdithIcon
    let label: String
    var active = false
    var tint: Color?
    let action: () -> Void

    public init(
        icon: EdithIcon, label: String, active: Bool = false, tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.active = active
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            EdithIconView(icon)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .accessibilityHidden(true)
        }
        .buttonStyle(.pageChip(active: active, tint: tint, iconOnly: true))
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

public struct PageMenuChip<Content: View>: View {
    let title: String
    var icon: EdithIcon?
    var dot: Color?
    var active = false
    var tint: Color?
    @ViewBuilder let content: () -> Content

    public init(
        _ title: String, icon: EdithIcon? = nil, dot: Color? = nil, active: Bool = false,
        tint: Color? = nil, @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.dot = dot
        self.active = active
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        Menu {
            content()
        } label: {
            PageChipLabel(title, icon: icon, dot: dot, menu: true)
        }
        .menuStyle(.button)
        .buttonStyle(.pageChip(active: active, tint: tint))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

public struct PageFilterBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        Grid(
            alignment: .leading, horizontalSpacing: UIScale.pt(PageMetrics.filterLabelSpacing),
            verticalSpacing: UIScale.pt(PageMetrics.filterRowSpacing)
        ) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct PageFilterRow<Content: View>: View {
    let label: String?
    @ViewBuilder let content: () -> Content

    public init(_ label: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    public var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            if let label {
                PageCapsLabel(label)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                chips
            } else {
                chips.gridCellColumns(2)
            }
        }
    }

    private var chips: some View {
        WrapHStack(
            spacing: UIScale.pt(PageMetrics.controlSpacing),
            lineSpacing: UIScale.pt(PageMetrics.controlSpacing)
        ) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
