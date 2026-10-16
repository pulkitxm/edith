import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

@MainActor @Observable final class HostRuntime {
    let updater = HostUpdater()
    private(set) var marketplace: HostMarketplace?
    private(set) var cliServer: HostCLIServer?
    private(set) var coreCLI: HostCoreCLIService?
    private(set) var coreServices: HostCoreServices?
    private(set) var sectionWindows: HostSectionWindows?
    private(set) var remotePresenter: HostRemoteContentPresenter?
    private(set) var windowNavigation: HostWindowNavigation?
    private(set) var musicSlots: HostMusicSlots?
    private(set) var machinesWindows: HostMachinesWindows?
    private(set) var terminalWindows: HostTerminalWindows?
    private(set) var herdrWindows: HostHerdrWindows?
    private(set) var herdrInteractions: HostHerdrInteractions?
    private(set) var notchStartup: HostNotchStartup?
    @ObservationIgnored private var notchAlerts: HostNotchAlerts?
    private(set) var startupError = false
    @ObservationIgnored private var startup: Task<Void, Never>?
    @ObservationIgnored private unowned let delegate: HostApplicationDelegate

    init(delegate: HostApplicationDelegate) {
        self.delegate = delegate
    }

    func launch() {
        guard startup == nil else { return }
        startup = Task { await start() }
    }

    private func start() async {
        guard marketplace == nil, !startupError else { return }
        let delegate = delegate
        let updater = updater
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
            Task.detached(priority: .utility) { HostLegacyServices.retire(identity: identity) }
            if !identity.development { HostLoginItem.register() }
            #endif
            let gateway = HostCLIGateway(marketplace: loaded)
            let core = try HostCoreCLIAdapter.make(
                identity: identity, marketplace: loaded, updater: updater,
                shared: SharedDefaults.store, standard: .standard,
                showMainWindow: { delegate.showMainWindow() },
                navigation: { action, route in
                    NavigationCommands.perform(action: action, route: route)
                }, core: { [weak self] in self?.coreServices },
                changed: { [weak self] in self?.coreServices?.panelShortcutChanged() })
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
                    HostWorkerNavigationRouting.activeVersions(
                        installed: loaded.installed, states: loaded.sessions.states,
                        versions: loaded.sessions.versions,
                        pendingDisable: loaded.sessions.pendingDisableIDs,
                        pendingRemoval: loaded.pendingRemovalIDs)
                },
                originatingWindow: { [weak presenter] in
                    presenter?.window(for: $0) ?? ownedNotch?.window(for: $0)
                },
                openWorkspace: {
                    guard let open = delegate.openMainWindow else {
                        throw HostWindowNavigationError.unavailable
                    }
                    open()
                },
                showWindow: { window in
                    delegate.showMainWindow(window)
                    await Task.yield()
                },
                windowIsPresented: { window in
                    window.isVisible && !window.isMiniaturized
                        && (window.isKeyWindow || window.attachedSheet === NSApp.keyWindow)
                        && NSApp.isActive
                }
            )
            let slots = HostMusicSlots.live(marketplace: loaded)
            let ownedMachines = HostMachinesWindows(
                manager: manager, presenter: presenter, navigation: navigation)
            let ownedHerdr = HostHerdrWindows(
                manager: manager, presenter: presenter, navigation: navigation)
            let ownedTerminal = HostTerminalWindows(
                manager: manager, presenter: presenter, navigation: navigation, identity: identity)
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
                marketplace: loaded, manager: manager, navigation: navigation,
                openTerminal: { [weak ownedTerminal] request in
                    guard let ownedTerminal else { throw HostWorkerError.rejected }
                    try await ownedTerminal.openSurface(
                        version: request.version, window: request.window, validate: request.validate
                    )
                })
            ownedNotch = notch
            notchStartup = notch
            loaded.sessions.didRequestNavigation = {
                [
                    weak manager, weak navigation, weak ownedMachines, weak ownedHerdr,
                    weak ownedTerminal, weak notch, weak self
                ]
                request in
                guard let manager, let navigation, let ownedMachines, let ownedHerdr,
                    let ownedTerminal
                else {
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
                } else if request.extensionID == "terminal" {
                    try await ownedTerminal.open(request)
                } else if request.extensionID == "studio", request.location == "settings" {
                    guard let windows = self?.sectionWindows, windows.open("studio") != nil
                    else { throw HostWorkerError.rejected }
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
                if id == "terminal" { try await ownedTerminal.stop() }
                if id == "machines" { try await ownedMachines.stop() }
                if id == "herdr" { try await ownedHerdr.stop() }
                try await disable(id)
            }
            windowNavigation = navigation
            musicSlots = slots
            machinesWindows = ownedMachines
            herdrWindows = ownedHerdr
            terminalWindows = ownedTerminal
            remotePresenter = presenter
            marketplace = loaded
            let alerts = HostNotchAlerts(
                namespace: identity.identifier, version: { updater.updateReady })
            alerts.start()
            notchAlerts = alerts
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
                        additionalSettings: { services.settings($0, presenter: presenter) },
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
            delegate.stopWorkers = {
                for pid in loaded.sessions.processIdentifiers.values where pid > 1 {
                    kill(-pid, SIGKILL)
                }
                HostRemoteSession.killAllForQuit()
                services.killForQuit()
            }
            delegate.preventsQuit = { await loaded.sessions.preventsQuit() }
            delegate.shutdown = {
                await interactions.cancelPending()
                let stops: [Task<Void, Never>] = [
                    Task { _ = try? await notch.stop() },
                    Task { _ = try? await ownedTerminal.stop() },
                    Task { _ = try? await ownedHerdr.stop() },
                    Task { await loaded.sessions.shutdown(reason: .applicationQuit) },
                ]
                for stop in stops { await stop.value }
                await interactions.stop()
                windows.closeAll(); windows.uninstall()
                await slots.stop()
                await services.shutdown(); core.shutdown(); control.shutdown()
            }
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in Task { @MainActor in await loaded.retryFailedExtensions() } }
            await services.start()
            await loaded.loadCachedCatalog()
            await loaded.refreshCatalogIfStale()
            await loaded.restoreEnabledExtensions()
            await loaded.updateInstalledIfDue()
        } catch { startupError = true }
    }

    func synchronizeAppearance() {
        guard let marketplace else { return }
        Task { await marketplace.sessions.synchronizeAppearance(identity: marketplace.identity) }
    }
}
