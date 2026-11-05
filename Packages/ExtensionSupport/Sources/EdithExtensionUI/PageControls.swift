import EdithIcons
import SwiftUI

public struct PageToolbarButton: View {
    let action: () -> Void
    let icon: EdithIcon
    let helperText: String
    var isLoading = false
    var tint: Color?

    public init(
        action: @escaping () -> Void, icon: EdithIcon, helperText: String,
        isLoading: Bool = false, tint: Color? = nil
    ) {
        self.action = action; self.icon = icon; self.helperText = helperText
        self.isLoading = isLoading; self.tint = tint
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    LoadingIndicator()
                } else {
                    EdithIconView(icon).foregroundStyle(tint ?? .primary)
                }
            }
            .frame(width: UIScale.pt(20), height: UIScale.pt(24))
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

public struct PageTabPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    @Environment(\.compactLayout) private var compact

    public init(
        _ title: String, selection: Binding<Option>, options: [Option],
        label: @escaping (Option) -> String
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        if compact {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: UIScale.pt(6)) {
                    Text(label(selection)).lineLimit(1)
                    EdithIconView(.chevronUpDown)
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.edithText(.body))
            }
            .menuStyle(.button)
            .buttonStyle(.edith(.secondary))
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(title)
        } else {
            EdithSegmentedPicker(title, selection: $selection, options: options, label: label)
                .labelsHidden()
        }
    }
}

public struct PageTabStrip<ID: Hashable, Content: View>: View {
    let selection: ID
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: ID, @ViewBuilder content: @escaping () -> Content) {
        self.selection = selection
        self.content = content
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) { content() }
                .scrollIndicators(.automatic)
                .task(id: selection) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.animation(Motion.snap, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
        }
    }
}
