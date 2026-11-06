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
    var requestedSettings: Binding<HostSettingsNavigation?> = .constant(nil)
    var presenter: (any HostExtensionContentPresenting)? = nil
    var showWelcome: (() -> Void)? = nil
    var panelShortcutChanged: () -> Void = {}
    var additionalSettings: ((String) -> AnyView?)? = nil
    var defaults: UserDefaults = SharedDefaults.store
    var showsIntroductionButton = false
    let select: (String) -> Void
    private var active: Set<String> { marketplace.surfaceAvailability.navigableIDs }
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
            .overlayPreferenceValue(HostIntroductionReopenKey.self, alignment: .topTrailing) {
                if showsIntroductionButton, let reopen = $0 {
                    HostIntroductionReopenButton(reopen: reopen)
                }
            }
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
            if destination.id == "appMaintenance",
                let child = HostNavigationCatalog.maintenanceDestination(
                    maintenanceSection, active: active), let id = child.extensionID
            {
                VStack(spacing: 0) {
                    maintenanceHeader(current: child, tight: id == "appMaintenance")
                    if id != "appMaintenance" { Divider() }
                    introduced(id, section: child.id)
                }
                .navigationRoute(
                    "tab",
                    selection: Binding(get: { child.id }, set: { maintenanceSection = $0 }),
                    isValid: { raw in maintenanceSections.contains { $0.id == raw } })
            } else if let id = destination.extensionID {
                introduced(id)
            } else {
                landing
            }
        }
    }
    private var maintenanceSections: [HostNavigationSection] {
        HostNavigationCatalog.maintenance.filter { $0.extensionID.map(active.contains) ?? false }
    }
    private func maintenanceHeader(current: HostNavigationSection, tight: Bool) -> some View {
        let sections = maintenanceSections
        return PageHeader(current.title, subtitle: current.summary) {
            Picker("Section", selection: $maintenanceSection) {
                ForEach(sections) { section in
                    Label(section.title, edith: section.icon).tag(section.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("App Maintenance section")
        }
        .padding(.bottom, tight ? -UIScale.pt(6) : 0)
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
        if let route = HostNavigationCatalog.route(extensionID: id) {
            if route.page == "appMaintenance", let section = route.section {
                maintenanceSection = section
            }
            if route.page == "settings", let section = route.section { settings = section }
            select(route.page)
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
    private func introduced(_ id: String, section: String? = nil) -> some View {
        HostIntroducedPage(
            entry: marketplace.entries.first { $0.id == id }, defaults: defaults,
            showsReopen: showsIntroductionButton
        ) {
            content(id, section: section)
        }
        .id(id + "/" + (section ?? ""))
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
