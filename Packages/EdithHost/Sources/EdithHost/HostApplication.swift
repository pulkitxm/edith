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
    @State private var coreCLI: HostCoreCLIService?
    @State private var coreServices: HostCoreServices?
    @State private var sectionWindows: HostSectionWindows?
    @State private var remotePresenter: HostRemoteContentPresenter?
    @State private var windowNavigation: HostWindowNavigation?
    @State private var musicSlots: HostMusicSlots?
    @State private var machinesWindows: HostMachinesWindows?
    @State private var herdrWindows: HostHerdrWindows?
    @State private var herdrInteractions: HostHerdrInteractions?
    @State private var notchStartup: HostNotchStartup?
    @State private var remoteCleanupNotice = false
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
                            marketplace: marketplace, presenter: remotePresenter, updater: updater,
                            showWelcome: { coreServices?.showWelcome() },
                            panelShortcutChanged: { coreServices?.panelShortcutChanged() },
                            additionalSettings: { coreServices?.settings($0) },
                            coreOnline: coreServices?.online ?? false,
                            coreSummary: coreServices?.activityLabel ?? "Starting",
                            sectionWindows: sectionWindows, windowNavigation: windowNavigation,
                            musicSlots: musicSlots)
                    } else if startupError {
                        ContentUnavailableView(
                            "Edith could not start", systemImage: "exclamationmark.triangle")
                    } else {
                        Text("Opening Edith")
                    }
                }
                .environment(\.compactLayout, geometry.size.width < UIScale.pt(720))
                .font(.system(size: UIScale.pt(13)))
                .controlSize(UIScale.controlSize)
                .disclosureGroupStyle(EdithDisclosureGroupStyle())
                .tint(themeColor(theme))
                #if EDITH_GUI_FIXTURE
                .background { HostGUIVisibilityProbe() }
                #endif
                .task { await start() }
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
            .onChange(of: remotePresenter?.cleanupFailed ?? false) {
                if remotePresenter?.cleanupFailed == true { remoteCleanupNotice = true }
            }
            .alert("Extension cleanup pending", isPresented: $remoteCleanupNotice) {
                Button("Retry cleanup") { remotePresenter?.retryCleanup() }
                Button("OK", role: .cancel) {}
            } message: {
                Text(
                    "The extension interface has closed, but its process has not confirmed cleanup. Retry before removing or updating it."
                )
            }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for App Updates") { updater.checkForUpdates() }.disabled(
                    !updater.available)
            }
        }
        Settings { HostSettingsRedirect() }
    }

    private func start() async {
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
            let core = try HostCoreCLIAdapter.make(
                identity: identity, marketplace: loaded, updater: updater,
                shared: SharedDefaults.store, standard: .standard,
                showMainWindow: { delegate.showMainWindow() },
                navigation: { action, route in
                    NavigationCommands.perform(action: action, route: route)
                }, core: { coreServices },
                changed: { coreServices?.panelShortcutChanged() })
            let control = HostCLIServer(identity: identity) { request in
                if HostCoreCLIService.handles(request) {
                    return try await core.execute(request)
                }
                return try await gateway.execute(request)
            }
            try control.start()
            cliServer = control
            coreCLI = core
            let manager = HostRemoteSessionManager(marketplace: loaded)
            let presenter = HostRemoteContentPresenter(manager: manager)
            weak var ownedNotch: HostNotchStartup?
            let navigation = HostWindowNavigation(
                activeVersions: {
                    loaded.sessions.versions.filter {
                        loaded.surfaceAvailability.activeIDs.contains($0.key)
                    }
                },
                originatingWindow: { [weak presenter] in
                    presenter?.window(for: $0) ?? ownedNotch?.window(for: $0)
                }
            )
            let slots = HostMusicSlots.live(marketplace: loaded)
            let ownedMachines = HostMachinesWindows(
                manager: manager, presenter: presenter, navigation: navigation)
            let ownedHerdr = HostHerdrWindows(
                manager: manager, presenter: presenter, navigation: navigation)
            let interactions = HostHerdrInteractions(
                marketplace: loaded, manager: manager, presenter: presenter,
                navigation: navigation, windows: ownedHerdr)
            interactions.install(delegate: delegate)
            herdrInteractions = interactions
            loaded.sessions.didRequestFolderChoice = { [weak interactions] request in
                guard let interactions else { throw HostWorkerError.rejected }
                return try await interactions.chooseFolder(request)
            }
            let notch = HostNotchStartup(
                marketplace: loaded, manager: manager, navigation: navigation)
            ownedNotch = notch
            notchStartup = notch
            loaded.sessions.didRequestNavigation = {
                [weak manager, weak navigation, weak ownedMachines, weak ownedHerdr, weak notch]
                request in
                guard let manager, let navigation, let ownedMachines, let ownedHerdr else {
                    throw HostWorkerError.rejected
                }
                try manager.validateNavigationOrigin(request)
                let notchOrigin = request.presentationID.flatMap { notch?.window(for: $0) }
                let notchTicket =
                    request.location == "notch"
                    ? request.presentationID.flatMap {
                        notch?.navigationTicket(
                            presentationID: $0, providerID: request.extensionID,
                            version: request.version)
                    } : nil
                guard request.location != "notch" || notchOrigin != nil else {
                    throw HostWorkerError.rejected
                }
                if request.machinesWindow != nil {
                    try await ownedMachines.open(request)
                } else if request.herdrWindow != nil {
                    try await ownedHerdr.open(request)
                } else {
                    try await navigation.navigate(
                        extensionID: request.extensionID, version: request.version,
                        section: request.section, relativePath: request.relativePath,
                        presentationID: request.presentationID,
                        location: request.location)
                }
                guard
                    request.location != "notch"
                        || request.presentationID.flatMap({ notch?.window(for: $0) })
                            === notchOrigin
                else { throw HostWorkerError.rejected }
                try manager.validateNavigationOrigin(request)
                if let notchTicket {
                    guard let notch else { throw HostWorkerError.rejected }
                    try await notch.navigationAcknowledged(notchTicket)
                }
            }
            let disable = loaded.sessions.willDisable
            loaded.sessions.willDisable = { id in
                if id == "music" { await slots.stop() }
                if id == "machines" { try await ownedMachines.stop() }
                if id == "herdr" { try await ownedHerdr.stop() }
                try await disable(id)
            }
            windowNavigation = navigation
            musicSlots = slots
            machinesWindows = ownedMachines
            herdrWindows = ownedHerdr
            remotePresenter = presenter
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
                        presenter: presenter, showWelcome: { services.showWelcome() },
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
                await interactions.cancelPending()
                do {
                    try await notch.stop()
                    try await ownedHerdr.stop()
                } catch { return false }
                let ready = await loaded.sessions.shutdown()
                if ready {
                    await interactions.stop()
                    windows.closeAll(); windows.uninstall()
                    await slots.stop()
                    await services.shutdown(); core.shutdown(); control.shutdown()
                }
                return ready
            }
            await services.start()
            await loaded.loadCachedCatalog()
            await loaded.restoreEnabledExtensions()
            await loaded.updateInstalledIfDue()
        } catch { startupError = true }
    }

    private func synchronizeAppearance() {
        guard let marketplace else { return }
        Task { await marketplace.sessions.synchronizeAppearance(identity: marketplace.identity) }
    }
}
