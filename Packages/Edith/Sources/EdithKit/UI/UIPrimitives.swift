import AppKit
import SwiftUI

public struct HoverButton: ViewModifier {
    @State private var hovering = false

    public init() {}

    @ViewBuilder
    public func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(UIScale.pt(4))
                .glassEffect(
                    .regular.interactive(), in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .onHover { hovering = $0 }
                .pointerCursor()
                .animation(.easeOut(duration: 0.12), value: hovering)
        } else {
            content
                .padding(UIScale.pt(4))
                .background(
                    .primary.opacity(hovering ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(6))
                        .strokeBorder(
                            .primary.opacity(hovering ? 0.18 : 0), lineWidth: UIScale.pt(0.5))
                )
                .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: UIScale.pt(4), y: 1)
                .onHover { hovering = $0 }
                .pointerCursor()
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

public struct HoverButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverButton())
            .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    public func hoverButton() -> some View { modifier(HoverButton()) }

    @ViewBuilder
    public func pointerCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onContinuousHover { phase in
                if case .active = phase {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
    }

    @ViewBuilder
    public func presenterBlur(_ on: Bool, radius: CGFloat = 4) -> some View {
        if on {
            blur(radius: UIScale.pt(radius))
        } else {
            self
        }
    }

    @ViewBuilder
    public func presenterCover(_ on: Bool, dark: Bool = true) -> some View {
        if on {
            compositingGroup()
                .blur(radius: UIScale.pt(28))
                .overlay {
                    (dark ? Color.black : Color.white).opacity(0.45)
                        .allowsHitTesting(false)
                }
                .privacySensitive(true)
        } else {
            self
        }
    }

    public func settingsCaption() -> some View {
        font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
    }

    @ViewBuilder
    public func card() -> some View {
        if #available(macOS 26.0, *) {
            padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        } else {
            padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .primary.opacity(0.05), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        }
    }

    public func widgetBar<F: ShapeStyle>(
        cornerRadius: CGFloat,
        fill: F,
        stroke: Color? = nil,
        strokeWidth: CGFloat = 1,
        shadow: Color? = nil,
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 8,
        clipsContent: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(cornerRadius))
        return
            self
            .background(fill, in: shape)
            .clipped(clipsContent, to: shape)
            .background {
                if let shadow {
                    shape.fill(fill)
                        .shadow(
                            color: shadow, radius: UIScale.pt(shadowRadius), y: UIScale.pt(shadowY))
                }
            }
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke, lineWidth: UIScale.pt(strokeWidth))
                }
            }
    }

    @ViewBuilder
    private func clipped<S: Shape>(_ clip: Bool, to shape: S) -> some View {
        if clip {
            clipShape(shape)
        } else {
            self
        }
    }

    @available(macOS 26.0, *)
    private func edithGlassStyle(_ tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    @ViewBuilder
    public func edithGlass<S: Shape>(_ tint: Color? = nil, interactive: Bool = false, in shape: S)
        -> some View
    {
        if #available(macOS 26.0, *) {
            self.glassEffect(edithGlassStyle(tint, interactive: interactive), in: shape)
        } else if let tint {
            self.background(tint.opacity(0.18), in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }
}

extension Color {
    public var hex6: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

public func eyebrow(_ text: String) -> some View {
    Text(text)
        .font(.system(size: UIScale.pt(10), weight: .semibold))
        .tracking(UIScale.pt(1.4))
        .foregroundStyle(.tertiary)
}

public struct EmptyStateText: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
    }
}

public struct TerminalLogView: View {
    let log: String
    let theme: Color
    var height: CGFloat = 140

    public init(log: String, theme: Color, height: CGFloat = 140) {
        self.log = log
        self.theme = theme
        self.height = height
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "No output yet - hit reload" : log)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .foregroundStyle(theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .onChange(of: log) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: height)
        .padding(UIScale.pt(8))
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }
}
