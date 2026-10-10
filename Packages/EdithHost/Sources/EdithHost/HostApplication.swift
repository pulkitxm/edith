import AppKit
import EdithHostCore
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct HostApplication: App {
    @State private var updater = HostUpdater()
    @NSApplicationDelegateAdaptor(HostApplicationDelegate.self) private var delegate
    @State private var marketplace: HostMarketplace?
    @State private var cliServer: HostCLIServer?
    @State private var coreServices: HostCoreServices?
    @State private var sectionWindows: HostSectionWindows?
    @Environment(\.openWindow) private var openWindow
    @State private var startupError = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var theme =
        "accent"
    @AppStorage(AppStorageKeys.General.appearance, store: SharedDefaults.store) private
        var appearance = "system"
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0

    var body: some Scene {
        WindowGroup("Edith", id: "main") {
            GeometryReader { geometry in
                Group {
                    if let marketplace {
                        HostWorkspace(
                            marketplace: marketplace, updater: updater,
                            panelShortcutChanged: { coreServices?.panelShortcutChanged() },
                            additionalSettings: { coreServices?.settings($0) },
                            coreOnline: coreServices?.online ?? false,
                            coreSummary: coreServices?.activityLabel ?? "Starting",
                            sectionWindows: sectionWindows)
                    } else if startupError {
                        ContentUnavailableView(
                            "Edith could not start", systemImage: "exclamationmark.triangle")
                    } else {
                        Text("Opening Edith")
                    }
                }
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(720))
                .tint(themeColor(theme))
                #if EDITH_GUI_FIXTURE
                .background { HostGUIVisibilityProbe() }
                #endif
                .task {
                    guard marketplace == nil, !startupError else { return }
                    do {
                        #if EDITH_GUI_FIXTURE
                        let loaded = try HostGUIFixture.make()
                        let identity = loaded.identity
                        #else
                        let support = try FileManager.default.url(
                            for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
                        let identity = try HostIdentity(
                            identifier: Bundle.main.bundleIdentifier
                                ?? "com.pulkit.edith.dev.extension-host-rebuild",
                            supportDirectory: support)
                        let loaded = try HostMarketplace.live(identity: identity)
                        #endif
                        let gateway = HostCLIGateway(marketplace: loaded)
                        let control = HostCLIServer(identity: identity) { request in
                            try await gateway.execute(request)
                        }
                        try control.start()
                        cliServer = control
                        marketplace = loaded
                        delegate.openMainWindow = { openWindow(id: "main") }
                        let services = try HostCoreServices(
                            identity: identity, marketplace: loaded,
                            togglePanel: { delegate.showMainWindow() })
                        coreServices = services
                        weak var detached: HostSectionWindows?
                        let windows = HostSectionWindows { page in
                            AnyView(
                                HostDetachedSection(
                                    marketplace: loaded, updater: updater, destination: page,
                                    panelShortcutChanged: { services.panelShortcutChanged() },
                                    additionalSettings: { services.settings($0) },
                                    select: { id in
                                        guard detached?.focusExisting(id) != true else { return }
                                        SharedDefaults.store.set(
                                            id, forKey: AppStorageKeys.General.mainWindowSection)
                                        delegate.showMainWindow()
                                    }))
                        }
                        detached = windows
                        sectionWindows = windows
                        windows.install()
                        delegate.shutdown = {
                            let ready = await loaded.sessions.shutdown()
                            if ready {
                                windows.closeAll(); windows.uninstall()
                                await services.shutdown(); control.shutdown()
                            }
                            return ready
                        }
                        await services.start()
                        await loaded.loadCachedCatalog()
                        await loaded.restoreEnabledExtensions()
                        await loaded.updateInstalledIfDue()
                    } catch { startupError = true }
                }
            }
            .tracksWindowVisibility()
            .frame(minWidth: 540, minHeight: 400)
            .onAppear {
                UIScale.apply(zoom); applyAppearance(appearance)
            }
            .onChange(of: zoom) {
                UIScale.apply(zoom); synchronizeAppearance()
            }
            .onChange(of: appearance) {
                applyAppearance(appearance); synchronizeAppearance()
            }
            .onChange(of: theme) { synchronizeAppearance() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for App Updates") { updater.checkForUpdates() }.disabled(
                    !updater.available)
            }
        }
        Settings { HostSettingsRedirect() }
    }

    private func synchronizeAppearance() {
        guard let marketplace else { return }
        Task { await marketplace.sessions.synchronizeAppearance(identity: marketplace.identity) }
    }
}
