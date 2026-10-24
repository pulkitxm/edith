import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct WorkspaceFilterList<Row: Identifiable, RowContent: View>: View {
    var label: String
    var rows: (String) -> [Row]
    var section: (Row) -> String
    var activate: (Row) -> Void
    var dismiss: () -> Void
    @ViewBuilder var rowContent: (Row, Bool, @escaping () -> Void) -> RowContent

    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var highlight = 0
    @State private var scrollToken = 0
    @State private var listHeight: CGFloat = 44

    private var dark: Bool { scheme == .dark }
    private var matches: [Row] { rows(query) }
    private var resolvedHighlight: Int { min(highlight, max(0, matches.count - 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            search
            if matches.isEmpty {
                Text("No matching filters")
                    .font(.edithText(.subheadline).weight(.medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.vertical, UIScale.pt(6))
            } else {
                list
            }
        }
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in
            highlight = 0
            scrollToken += 1
        }
    }

    private var search: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.edithText(.body))
                .disableAutocorrection(true)
                .focused($searchFocused)
                .accessibilityLabel(label)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let count = matches.count
                    guard count > 0 else { return .handled }
                    highlight = WorkspaceFilterNavigation.highlight(
                        resolvedHighlight, movingBy: press.key == .upArrow ? -1 : 1, count: count)
                    scrollToken += 1
                    return .handled
                }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .onKeyPress(keys: [.return]) { _ in
                    let rows = matches
                    if rows.indices.contains(resolvedHighlight) {
                        activate(rows[resolvedHighlight])
                    }
                    return .handled
                }
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(6))
        .widgetBar(cornerRadius: 8, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
    }

    private var list: some View {
        let rows = matches
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == 0 || section(rows[index - 1]) != section(row) {
                            Text(section(row))
                                .font(.system(size: UIScale.pt(10), weight: .semibold))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .padding(.horizontal, UIScale.pt(8))
                                .padding(.top, UIScale.pt(index == 0 ? 2 : 10))
                                .padding(.bottom, UIScale.pt(2))
                                .accessibilityAddTraits(.isHeader)
                        }
                        rowContent(row, index == resolvedHighlight) {
                            highlight = index
                            activate(row)
                        }
                        .id(row.id)
                        .onHover { if $0 { highlight = index } }
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: WorkspaceFilterListHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 44), UIScale.pt(420)))
            .onPreferenceChange(WorkspaceFilterListHeightKey.self) { listHeight = $0 }
            .onChange(of: scrollToken) { _, _ in
                guard rows.indices.contains(resolvedHighlight) else { return }
                proxy.scrollTo(rows[resolvedHighlight].id, anchor: .center)
            }
        }
    }
}

enum WorkspaceFilterNavigation {
    static func highlight(_ current: Int, movingBy delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count - 1, max(0, current + delta))
    }
}

private struct WorkspaceFilterListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
