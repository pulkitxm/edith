import SwiftUI

private struct EdithSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: UIScale.pt(cornerRadius), style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.3 : 0.07),
                    lineWidth: contrast == .increased ? 1 : 0.5
                )
                .allowsHitTesting(false)
            }
    }
}

public struct EdithDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: UIScale.pt(12)) {
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: UIScale.pt(16), height: UIScale.pt(20))
                        .accessibilityHidden(true)
                }
                .padding(UIScale.pt(8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.bottom, UIScale.pt(10))
            }
        }
    }
}

extension View {
    public func edithSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(EdithSurface(cornerRadius: cornerRadius))
    }
}
