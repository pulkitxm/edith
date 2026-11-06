import EdithExtensionUI
import SwiftUI

struct HostSettingsContainer<Content: View>: View {
    @Binding var category: String
    var sections: [HostNavigationSection] = HostNavigationCatalog.settings
    @ViewBuilder let content: () -> Content
    @Environment(\.compactLayout) private var compact
    private var section: HostNavigationSection {
        sections.first { $0.id == category } ?? HostNavigationCatalog.settings[0]
    }
    var body: some View {
        PageWorkspace {
            PageHeader(section.title, subtitle: section.summary) {
                Picker("Category", selection: $category) {
                    ForEach(sections) { item in
                        Label(item.title, edith: item.icon).tag(item.id)
                    }
                }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Settings category")
            }
            .environment(\.pageColumnWidth, columnWidth)
        } content: {
            content().scrollContentBackground(.hidden)
                .padding(.horizontal, columnWidth == nil ? 0 : formEdgeAlignment)
                .frame(maxWidth: columnWidth ?? .infinity, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationRoute(
            "tab", selection: $category,
            isValid: { raw in sections.contains { $0.id == raw } }
        )
        .navigationTitle(section.title)
    }
    private var formEdgeAlignment: CGFloat {
        PageMetrics.gutter(compact) - PageMetrics.groupedFormInset
    }

    private var columnWidth: CGFloat? {
        guard !["permissions", "storage", "surfaces"].contains(section.id) else { return nil }
        return min(
            UIScale.pt(PageMetrics.formWidth),
            PageMetrics.formWidth + 2 * PageMetrics.gutter(compact))
    }
}
