import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostDetachedSection: View {
    let marketplace: HostMarketplace
    let updater: HostUpdater
    let destination: HostNavigationPage
    var presenter: (any HostExtensionContentPresenting)? = nil
    var showWelcome: (() -> Void)? = nil
    var panelShortcutChanged: () -> Void = {}
    var additionalSettings: ((String) -> AnyView?)? = nil
    let select: (String) -> Void
    @State private var permissions = HostPermissions()
    @State private var router = WindowRouter()
    @AppStorage(AppStorageKeys.General.settingsTab, store: SharedDefaults.store) private
        var settings = "general"
    @AppStorage(AppStorageKeys.AppMaintenance.section, store: SharedDefaults.store) private
        var maintenance = "Updates"
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationRouteHost(router: router) {
            GeometryReader { geometry in
                HostPageContent(
                    marketplace: marketplace, updater: updater, permissions: permissions,
                    destination: destination, settings: $settings, maintenanceSection: $maintenance,
                    presenter: presenter, showWelcome: showWelcome,
                    panelShortcutChanged: panelShortcutChanged,
                    additionalSettings: additionalSettings,
                    select: select
                )
                .font(.system(size: UIScale.pt(13)))
                .controlSize(UIScale.controlSize)
                .disclosureGroupStyle(EdithDisclosureGroupStyle())
                .tint(themeColor(theme))
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(640))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DashSkin.paper(scheme == .dark))
            }
            .navigationRoute(
                "section", selection: Binding(get: { destination.id }, set: { _ in }),
                isValid: { $0.isEmpty || $0 == destination.id })
        }
        .tracksWindowVisibility()
    }
}
