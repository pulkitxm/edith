import AppKit
import SwiftUI

public struct HoverButton: ViewModifier {
    @State private var hovering = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(4)
            .background(
                .primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.primary.opacity(hovering ? 0.18 : 0), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: 4, y: 1)
            .onHover { hovering = $0 }
            .pointerCursor()
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

public struct HoverButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverButton())
            .contentShape(RoundedRectangle(cornerRadius: 6))
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

    public func presenterBlur(_ on: Bool) -> some View {
        blur(radius: on ? 4 : 0)
    }

    public func card() -> some View {
        padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

public func eyebrow(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(.tertiary)
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
                Text(log.isEmpty ? "No output yet — hit reload" : log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .onChange(of: log) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: height)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}
