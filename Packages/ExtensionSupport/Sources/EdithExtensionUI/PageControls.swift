import EdithIcons
import SwiftUI

enum PageToolbarMetrics {
    static let glyphWidth = 20.0
    static let glyphHeight = 24.0
}

struct PageToolbarIconStyle: ButtonStyle {
    let tint: Color?
    let font: Font?

    func makeBody(configuration: Configuration) -> some View {
        EdithButtonBody(
            label: configuration.label
                .foregroundStyle(tint ?? .primary)
                .transformEnvironment(\.font) { value in
                    if let font { value = font }
                }
                .frame(
                    width: UIScale.pt(PageToolbarMetrics.glyphWidth),
                    height: UIScale.pt(PageToolbarMetrics.glyphHeight)),
            role: .toolbar, selected: false, pressed: configuration.isPressed, tint: nil)
    }
}

public struct PageToolbarButton: View {
    let action: () -> Void
    let icon: EdithIcon
    let helperText: String
    var label: String?
    var isLoading = false
    var tint: Color?
    var font: Font?

    public init(
        action: @escaping () -> Void, icon: EdithIcon, helperText: String,
        accessibilityLabel: String? = nil, isLoading: Bool = false, tint: Color? = nil,
        font: Font? = nil
    ) {
        self.action = action; self.icon = icon; self.helperText = helperText
        self.label = accessibilityLabel; self.isLoading = isLoading; self.tint = tint
        self.font = font
    }

    public var body: some View {
        Button(action: action) {
            if isLoading {
                LoadingIndicator()
            } else {
                EdithIconView(icon)
            }
        }
        .buttonStyle(PageToolbarIconStyle(tint: tint, font: font))
        .disabled(isLoading)
        .help(helperText)
        .accessibilityLabel(label ?? helperText)
    }
}

public struct PageToolbarMenu<Content: View>: View {
    let icon: EdithIcon
    let helperText: String
    var label: String?
    var tint: Color?
    var font: Font?
    @ViewBuilder let content: () -> Content

    public init(
        icon: EdithIcon, helperText: String, accessibilityLabel: String? = nil,
        tint: Color? = nil, font: Font? = nil, @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon; self.helperText = helperText; self.label = accessibilityLabel
        self.tint = tint; self.font = font; self.content = content
    }

    public var body: some View {
        Menu(content: content) {
            EdithIconView(icon)
        }
        .menuStyle(.button)
        .buttonStyle(PageToolbarIconStyle(tint: tint, font: font))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helperText)
        .accessibilityLabel(label ?? helperText)
    }
}

public struct PageToolbarMenuButton: View {
    let icon: EdithIcon
    let helperText: String
    var label: String?
    var tint: Color?
    var font: Font?
    let items: @MainActor () -> [EdithMenuItem]

    public init(
        icon: EdithIcon, helperText: String, accessibilityLabel: String? = nil,
        tint: Color? = nil, font: Font? = nil,
        items: @escaping @MainActor () -> [EdithMenuItem]
    ) {
        self.icon = icon; self.helperText = helperText; self.label = accessibilityLabel
        self.tint = tint; self.font = font; self.items = items
    }

    public var body: some View {
        EdithMenuButton(items: items) {
            EdithIconView(icon)
        }
        .buttonStyle(PageToolbarIconStyle(tint: tint, font: font))
        .fixedSize()
        .help(helperText)
        .accessibilityLabel(label ?? helperText)
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
