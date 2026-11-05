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
            PageHeader(section.title, subtitle: HostSettingsSummary.text(section.id)) {
                Picker("Category", selection: $category) {
                    ForEach(sections) { item in
                        Label(item.title, systemImage: item.symbol).tag(item.id)
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
enum HostSettingsSummary {
    static func text(_ id: String) -> String? {
        switch id {
        case "general": "Appearance, window, and welcome tour"
        case "surfaces": "Arrange widgets and build your own Home and Notch"
        case "agentActivity": "Live provider activity and explicit permission approvals"
        case "permissions": "Privacy access used by enabled extensions"
        case "agent": "Keeps your tools up to date while the Edith window is closed"
        case "jev": "Fast typed decisions from TypeSafe's Jev model"
        case "data": "Where Edith keeps things, and what leaves this Mac"
        case "storage": "Measured app, extension packages, cache and retained user data"
        case "shortcuts": "Global and application keyboard shortcuts"
        case "terminal": "Command line and terminal integration"
        case "icloud": "Backup and synchronization"
        case "updates": "Version and automatic update behavior"
        default: nil
        }
    }
}
