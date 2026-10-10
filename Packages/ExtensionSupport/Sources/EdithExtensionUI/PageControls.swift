import SwiftUI

public struct PageToolbarButton: View {
    let action: () -> Void
    let systemImage: String
    let helperText: String
    var isLoading = false
    var tint: Color?

    public init(
        action: @escaping () -> Void, systemImage: String, helperText: String,
        isLoading: Bool = false, tint: Color? = nil
    ) {
        self.action = action; self.systemImage = systemImage; self.helperText = helperText
        self.isLoading = isLoading; self.tint = tint
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    LoadingIndicator()
                } else {
                    Image(systemName: systemImage).foregroundStyle(tint ?? .primary)
                }
            }
            .frame(width: UIScale.pt(30), height: UIScale.pt(30))
        }
        .buttonStyle(.edith(.toolbar))
        .disabled(isLoading)
        .help(helperText)
        .accessibilityLabel(helperText)
    }
}

public struct PageColumns<Content: View>: View {
    var spacing = PageMetrics.sectionSpacing
    @ViewBuilder let content: () -> Content
    @Environment(\.compactLayout) private var compact

    public init(
        spacing: Double = PageMetrics.sectionSpacing, @ViewBuilder content: @escaping () -> Content
    ) { self.spacing = spacing; self.content = content }

    public var body: some View {
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(spacing)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: UIScale.pt(spacing)))
        layout { content() }
    }
}
