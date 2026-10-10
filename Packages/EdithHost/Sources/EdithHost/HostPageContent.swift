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

    @ViewBuilder var body: some View {
        switch destination.id {
        case "home":
            HostHomePage(
                marketplace: marketplace, customize: customize,
                extensions: { select("extensions") }, openExtension: openExtension,
                presenter: presenter)
        case "extensions": MarketplacePage(marketplace: marketplace, presenter: presenter)
        case "settings": HostSettingsContainer(category: $settings) { settingsContent }
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
        switch settings {
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
        case "updates": HostUpdatesPane(updater: updater)
        case "shortcuts":
            HostShortcutsPane(marketplace: marketplace, panelShortcutChanged: panelShortcutChanged)
        default:
            if let section = HostNavigationCatalog.settings.first(where: { $0.id == settings }),
                let id = section.extensionID
            {
                content(id, section: settings)
            } else if let view = additionalSettings?(settings) {
                view
            } else {
                ContentUnavailableView(
                    HostNavigationCatalog.settings.first(where: { $0.id == settings })?.title
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
        PageScaffold(width: .fluid) {
            PageHeader(destination.title)
        } content: {
            ForEach(
                marketplace.entries.filter {
                    active.contains($0.id)
                        && (HostNavigationCatalog.suiteProviders[destination.suite ?? ""] ?? [])
                            .contains($0.id)
                }
            ) { entry in
                HostSurfaceCard(
                    marketplace: marketplace, target: .home, tile: .init(.ability(entry.id))
                )
            }
        }
    }
    private func customize() { settings = "surfaces"; select("settings") }
}
