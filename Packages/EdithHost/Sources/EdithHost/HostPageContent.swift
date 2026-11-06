import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostPageContent: View {
    let marketplace: HostMarketplace
    let updater: HostUpdater
    let permissions: HostPermissions
    let destination: HostNavigationPage
    @Binding var settings: String
    var requestedSettings: Binding<HostSettingsNavigation?> = .constant(nil)
    var presenter: (any HostExtensionContentPresenting)? = nil
    var showWelcome: (() -> Void)? = nil
    var panelShortcutChanged: () -> Void = {}
    var additionalSettings: ((String) -> AnyView?)? = nil
    var defaults: UserDefaults = SharedDefaults.store
    var showsIntroductionButton = false
    let select: (String) -> Void
    private var settingsSections: [HostNavigationSection] {
        HostNavigationCatalog.settingsSections(
            installed: Set(marketplace.installed.keys),
            pending: marketplace.sessions.pendingDisableIDs.union(marketplace.pendingRemovalIDs))
    }
    private var settingsDestination: String {
        settingsSections.contains { $0.id == settings } ? settings : "general"
    }
    private var settingsBinding: Binding<String> {
        Binding(get: { settingsDestination }, set: { settings = $0 })
    }

    var body: some View {
        page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var page: some View {
        switch destination.id {
        case "home":
            HostHomePage(
                marketplace: marketplace, customize: customize,
                extensions: { select("extensions") }, openExtension: openExtension,
                presenter: presenter, workflowSetup: additionalSettings?("home-setup"),
                getStarted: AnyView(
                    HostGetStartedCard(
                        marketplace: marketplace, permissions: permissions, defaults: defaults,
                        finishSetup: showWelcome, openPermissions: openPermissions,
                        openAgents: openAgents, openExtensions: { select("extensions") },
                        openExtension: openExtension)))
        case "extensions":
            MarketplacePage(
                marketplace: marketplace, presenter: presenter, openExtension: openExtension,
                requestedSettings: requestedSettings)
        case "settings":
            HostSettingsContainer(category: settingsBinding, sections: settingsSections) {
                settingsContent
            }
        case "about": HostAboutPage(identity: marketplace.identity)
        default:
            if let id = destination.extensionID {
                introduced(id)
            } else {
                landing
            }
        }
    }
    @ViewBuilder private var settingsContent: some View {
        switch settingsDestination {
        case "terminal": HostToolingSettingsPage(defaults: defaults)
        case "mcp": HostAgentsSettingsPage(defaults: defaults)
        case "surfaces": HostSurfaceEditor(marketplace: marketplace)
        case "general":
            HostSettingsPage(
                marketplace: marketplace, permissions: permissions, defaults: defaults,
                openPermissions: { settings = "permissions" }, showWelcome: showWelcome,
                panelShortcutChanged: panelShortcutChanged)
        case "permissions":
            HostPermissionsPane(
                marketplace: marketplace, permissions: permissions,
                openExtensions: { select("extensions") })
        case "storage": HostStoragePage(marketplace: marketplace)
        case "updates": HostUpdatesPane(updater: updater)
        case "shortcuts":
            HostShortcutsPane(marketplace: marketplace, panelShortcutChanged: panelShortcutChanged)
        default:
            if let section = settingsSections.first(where: { $0.id == settingsDestination }),
                let id = section.extensionID
            {
                content(
                    id,
                    section: HostExtensionSettingsPolicy.route(for: id)?.section
                        ?? settingsDestination)
            } else if let view = additionalSettings?(settingsDestination) {
                view
            } else {
                ContentUnavailableView {
                    Label(
                        settingsSections.first(where: { $0.id == settingsDestination })?.title
                            ?? "General", edith: .gear)
                }
            }
        }
    }
    private func openExtension(_ id: String) {
        if let page = HostNavigationCatalog.route(extensionID: id) {
            select(page)
        } else {
            defaults.set(id, forKey: HostMarketplaceKeys.expandedExtension)
            select("extensions")
        }
    }
    private func openPermissions() {
        settings = "permissions"
        select("settings")
    }
    private func openAgents() {
        settings = "mcp"
        select("settings")
    }
    private func introduced(_ id: String) -> some View {
        HostIntroducedPage(
            entry: marketplace.entries.first { $0.id == id }, defaults: defaults,
            showsReopen: showsIntroductionButton
        ) {
            content(id)
        }
        .id(id)
    }
    private func content(_ id: String, section: String? = nil) -> some View {
        HostExtensionContent(
            marketplace: marketplace, extensionID: id,
            location: destination.id == "settings" ? "settings" : "main",
            section: section ?? destination.id,
            presenter: presenter, openMarketplace: { select("extensions") })
    }
    private var landing: some View {
        HostSuiteLandingPage(
            marketplace: marketplace, destination: destination, presenter: presenter,
            openExtension: openExtension)
    }
    private func customize(_ tileID: String?) {
        HostSurfaceEditorRequest(target: .home, tileID: tileID).save(
            to: marketplace.surfaces.preferences)
        settings = "surfaces"
        select("settings")
    }
}
