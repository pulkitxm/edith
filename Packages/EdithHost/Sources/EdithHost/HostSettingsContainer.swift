import EdithExtensionUI
import SwiftUI

struct HostSettingsContainer<Content: View>: View {
    @Binding var category: String
    @ViewBuilder let content: () -> Content
    private var section: HostNavigationSection {
        HostNavigationCatalog.settings.first { $0.id == category }
            ?? HostNavigationCatalog.settings[0]
    }
    var body: some View {
        PageWorkspace {
            PageHeader(
                section.title,
                trailing: {
                    Picker("Category", selection: $category) {
                        ForEach(HostNavigationCatalog.settings) { item in
                            Label(item.title, systemImage: item.symbol).tag(item.id)
                        }
                    }.pickerStyle(.menu).labelsHidden().accessibilityLabel("Settings category")
                },
                accessory: {
                    Text(HostSettingsSummary.text(section.id)).font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(.secondary)
                })
        } content: {
            content().scrollContentBackground(.hidden)
                .frame(maxWidth: maximumWidth, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationRoute(
            "tab", selection: $category,
            isValid: { raw in HostNavigationCatalog.settings.contains { $0.id == raw } }
        )
        .navigationTitle(section.title)
    }
    private var maximumWidth: CGFloat {
        ["permissions", "agent", "data", "surfaces", "agentActivity"].contains(section.id)
            ? .infinity : UIScale.pt(1180)
    }
}
enum HostSettingsSummary {
    static func text(_ id: String) -> String {
        switch id {
        case "general": "Appearance, window, and welcome tour"
        case "surfaces": "Arrange widgets and build your own Home and Notch"
        case "agentActivity": "Live provider activity and explicit permission approvals"
        case "permissions": "Privacy access used by enabled extensions"
        case "agent": "The headless process that collects in the background"
        case "jev": "Fast typed decisions from TypeSafe's Jev model"
        case "data": "Where Edith keeps things, and what leaves this Mac"
        case "shortcuts": "Global and application keyboard shortcuts"
        case "terminal": "Command line and terminal integration"
        case "icloud": "Backup and synchronization"
        case "updates": "Version and automatic update behavior"
        default: ""
        }
    }
}
