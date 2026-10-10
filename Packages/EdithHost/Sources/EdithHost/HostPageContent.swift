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
    @Binding var maintenanceSection: String
    var presenter: (any HostExtensionContentPresenting)? = nil
    var showWelcome: (() -> Void)? = nil
    var panelShortcutChanged: () -> Void = {}
    var additionalSettings: ((String) -> AnyView?)? = nil
    var defaults: UserDefaults = SharedDefaults.store
    let select: (String) -> Void
    private var active: Set<String> { marketplace.surfaceAvailability.activeIDs }
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

    @ViewBuilder var body: some View {
        switch destination.id {
        case "home":
            HostHomePage(
                marketplace: marketplace, customize: customize,
                extensions: { select("extensions") }, openExtension: openExtension,
                presenter: presenter, workflowSetup: additionalSettings?("home-setup"))
        case "extensions":
            MarketplacePage(
                marketplace: marketplace, presenter: presenter, openExtension: openExtension)
        case "settings":
            HostSettingsContainer(category: settingsBinding, sections: settingsSections) {
                settingsContent
            }
        case "about": HostAboutPage(identity: marketplace.identity)
        default:
            if destination.id == "appMaintenance",
                let child = HostNavigationCatalog.maintenance.first(where: {
                    $0.id == maintenanceSection
                }), let id = child.extensionID
            {
                content(id, section: child.id)
            } else if let id = destination.extensionID {
                content(id)
            } else {
                landing
            }
        }
    }
    @ViewBuilder private var settingsContent: some View {
        switch settingsDestination {
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
        case "storage": HostStoragePage(marketplace: marketplace, updater: updater)
        case "updates": HostUpdatesPane(updater: updater)
        case "shortcuts":
            HostShortcutsPane(marketplace: marketplace, panelShortcutChanged: panelShortcutChanged)
        default:
            if let section = settingsSections.first(where: { $0.id == settingsDestination }),
                let id = section.extensionID
            {
                content(id, section: settingsDestination)
            } else if let view = additionalSettings?(settingsDestination) {
                view
            } else {
                ContentUnavailableView(
                    settingsSections.first(where: { $0.id == settingsDestination })?.title
                        ?? "General", systemImage: "gearshape")
            }
        }
    }
    private func openExtension(_ id: String) {
        if let route = HostNavigationCatalog.route(extensionID: id) {
            if route.page == "appMaintenance", let section = route.section {
                maintenanceSection = section
            }
            select(route.page)
        } else {
            defaults.set(id, forKey: HostMarketplaceKeys.expandedExtension)
            select("extensions")
        }
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
    private func customize() { settings = "surfaces"; select("settings") }
}
