import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import WebKit

@MainActor
@Observable
final class NotchBrowserStore {
    enum SyncState: Equatable {
        case idle
        case unlocking
        case importing(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .unlocking, .importing: true
            case .idle, .failed: false
            }
        }
    }

    let installation: ChromeInstallation
    private(set) var readiness: ChromeReadiness = .notInstalled
    private(set) var profiles: [ChromeProfile] = []
    private(set) var profile: ChromeProfile?
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: BrowserTab.ID?
    private(set) var syncState: SyncState = .idle { didSet { remote?.held(holdsOpen) } }
    private(set) var syncSummary: String?
    private(set) var size: CGSize
    private(set) var isResizing = false { didSet { remote?.held(holdsOpen) } }
    private(set) var menuDepth = 0 { didSet { remote?.held(holdsOpen) } }
    private(set) var filePanelOpen = false { didSet { remote?.held(holdsOpen) } }
    private(set) var dialog: BrowserDialog? { didSet { remote?.held(holdsOpen) } }
    private(set) var toast: String?
    private(set) var addressFocusRequest = 0
    private(set) var choosingProfile = false

    @ObservationIgnored var screenSize: () -> CGSize? = { nil }
    @ObservationIgnored var onSizeChange: (() -> Void)?
    @ObservationIgnored var requestKeyFocus: (() -> Void)?
    @ObservationIgnored var onProfileChange: (() -> Void)?
    @ObservationIgnored private let sessionFile: BrowserSessionFile
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let remote: NotchBrowserRemoteClient?
    @ObservationIgnored private let keyProvider: @Sendable () throws -> ChromeCookieKey
    @ObservationIgnored private let dataStoreFactory: @MainActor (UUID) -> WKWebsiteDataStore
    @ObservationIgnored private var session: BrowserSession
    @ObservationIgnored private var dataStore: WKWebsiteDataStore?
    @ObservationIgnored private var cookieKey: ChromeCookieKey?
    @ObservationIgnored private var cookieWatermark: Date?
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private(set) var pendingSeeds: [String: [String: String]] = [:]
    @ObservationIgnored private var closedTabs: [URL] = []
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var remoteDownloads:
        [ObjectIdentifier: (NotchBrowserDownloadDescriptor, URL)] = [:]
    @ObservationIgnored private var deliveries: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloads: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var faviconCache: [String: NSImage] = [:]
    @ObservationIgnored private var faviconTasks: [BrowserTab.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var resizeStart:
        (size: CGSize, pointer: CGPoint, edge: NotchBrowserResizeEdge)?
    @ObservationIgnored private var menuObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var storeDrains: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var nativeDownloads: [ObjectIdentifier: WKDownload] = [:]
    @ObservationIgnored private var contentControllers:
        [ObjectIdentifier: WKUserContentController] = [:]
    @ObservationIgnored private let faviconSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()
    @ObservationIgnored private lazy var delegate = NotchBrowserWebDelegate(store: self)

    static let syncInterval: TimeInterval = 300
    static let closedTabLimit = 20

    init(
        installation: ChromeInstallation = .live,
        sessionFile: BrowserSessionFile = .standard,
        defaults: UserDefaults = SharedDefaults.store,
        keyProvider: @escaping @Sendable () throws -> ChromeCookieKey = {
            try ChromeSafeStorage.keychainKey()
        },
        dataStoreFactory: @escaping @MainActor (UUID) -> WKWebsiteDataStore = {
            WKWebsiteDataStore(forIdentifier: $0)
        }, remote: NotchBrowserRemoteClient? = nil
    ) {
        self.remote = remote
        self.installation = installation
        self.sessionFile = sessionFile
        self.defaults = defaults
        self.keyProvider = keyProvider
        self.dataStoreFactory = dataStoreFactory
        session = remote?.state.session ?? sessionFile.load()
        size = NotchBrowserGeometry.clamp(
            session.size ?? NotchBrowserGeometry.defaultSize, screen: nil)
        refreshEnvironment()
        if let directory = session.profile,
            let saved = profiles.first(where: { $0.directory == directory })
        {
            profile = saved
            session.profileName = saved.name
            if remote == nil {
                dataStore = dataStoreFactory(
                    ChromeProfileImporter.dataStoreIdentifier(
                        profile: saved, userData: installation.userData))
            }
        }
        observeMenus()
        remote?.updated = { [weak self] state in self?.applyRemoteState(state) }
        remote?.failed = { [weak self] message in self?.syncState = .failed(message) }
        remote?.revoked = { [weak self] in self?.revokePresentation() }
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }

    var holdsOpen: Bool {
        isResizing || menuDepth > 0 || filePanelOpen || dialog != nil || syncState == .unlocking
    }

    var showsSetup: Bool { profile == nil || choosingProfile }

    var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine(
            rawValue: remote?.state.searchEngine ?? defaults.string(
                forKey: AppStorageKeys.Notch.browserSearchEngine) ?? "")
            ?? .google
    }

    func shutdown() {
        guard !stopped else { return }
        saveSession()
        stopped = true
        let syncing = syncTask
        let delivering = Array(deliveries.values)
        let favicons = Array(faviconTasks.values)
        syncTask?.cancel()
        toastTask?.cancel()
        delivering.forEach { $0.cancel() }
        revokePresentation()
        faviconSession.invalidateAndCancel()
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers = []
        remote?.stop()
        teardown = Task {
            await syncing?.value
            for task in delivering + favicons { await task.value }
            await drainStores()
            await remote?.stopAndWait()
            deliveries = [:]; faviconTasks = [:]; faviconCache = [:]
        }
    }

    func shutdownAndWait() async { shutdown(); await teardown?.value }

    var permitsNativeNavigation: Bool {
        !stopped && (remote == nil || remote?.hasLiveLease == true)
    }

    private func revokePresentation() {
        syncTask?.cancel()
        closeAllTabs()
        for controller in contentControllers.values {
            controller.removeScriptMessageHandler(forName: LocalStorageSeed.messageName)
            controller.removeAllUserScripts()
        }
        contentControllers = [:]
        for download in nativeDownloads.values {
            download.delegate = nil
            let id = UUID()
            storeDrains[id] = Task {
                await withCheckedContinuation { continuation in
                    download.cancel { _ in continuation.resume() }
                }
            }
        }
        nativeDownloads = [:]
        for (_, url) in remoteDownloads.values {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        remoteDownloads = [:]
        if let dataStore { drain(dataStore, after: syncTask) }
        dataStore = nil
        pendingSeeds = [:]; closedTabs = []; cookieKey = nil
        cookieWatermark = nil; lastSync = nil
    }

    private func drain(_ store: WKWebsiteDataStore, after task: Task<Void, Never>? = nil) {
        let id = UUID()
        storeDrains[id] = Task {
            await task?.value
            let cookies = await store.httpCookieStore.allCookies()
            for cookie in cookies { await store.httpCookieStore.deleteCookie(cookie) }
            await store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    func drainStores() async {
        let tasks = storeDrains
        for task in tasks.values { await task.value }
        for id in tasks.keys { storeDrains[id] = nil }
    }

    func refreshEnvironment() {
        if let remote { applyRemoteState(remote.state); remote.perform(.read); return }
        let inspection = installation.inspect()
        readiness = inspection.readiness
        profiles = inspection.profiles
    }

    func appeared() {
        guard !stopped else { return }
        guard let profile, !choosingProfile else {
            refreshEnvironment()
            return
        }
        if tabs.isEmpty, permitsNativeNavigation { restoreTabs() }
        if let lastSync, Date().timeIntervalSince(lastSync) < Self.syncInterval { return }
        load(profile, full: lastSync == nil)
    }

    func chooseProfile() {
        refreshEnvironment()
        choosingProfile = true
    }

    func cancelChoosingProfile() {
        guard profile != nil else { return }
        choosingProfile = false
    }

    func makeChromeDefault() {
        if let remote { remote.perform(.makeDefault); return }
        installation.makeDefaultBrowser { [weak self] _ in self?.refreshEnvironment() }
    }

    func downloadChrome() {
        if let remote { remote.perform(.downloadChrome); return }
        NSWorkspace.shared.open(ChromeInstallation.downloadURL)
    }

    func openPrivacySettings() {
        if let remote { remote.perform(.privacy); return }
        NSWorkspace.shared.open(ChromeInstallation.privacySettingsURL)
    }

    func attach(_ chosen: ChromeProfile) {
        load(chosen, full: true)
    }

    func syncNow() {
        guard let profile else { return }
        load(profile, full: true)
    }

    func detach() {
        remote?.perform(.detach)
        syncTask?.cancel()
        syncState = .idle
        syncSummary = nil
        if remote != nil {
            revokePresentation()
            let id = UUID()
            storeDrains[id] = Task { await remote?.endLease() }
        } else {
            closeAllTabs()
        }
        let released = dataStore
        let identifier = profile.map {
            ChromeProfileImporter.dataStoreIdentifier(profile: $0, userData: installation.userData)
        }
        dataStore = nil
        profile = nil
        cookieWatermark = nil
        lastSync = nil
        pendingSeeds = [:]
        closedTabs = []
        choosingProfile = false
        session.profile = nil
        session.profileName = nil
        session.tabs = []
        session.selected = 0
        persistSession()
        refreshEnvironment()
        onProfileChange?()
        guard let released, let identifier else { return }
        released.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) {
            WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in }
        }
    }

    private func load(_ target: ChromeProfile, full: Bool) {
        guard !stopped else { return }
        if let remote {
            syncTask?.cancel()
            syncState = .unlocking
            syncTask = Task { [weak self] in
                do {
                    let (descriptor, snapshot) = try await remote.importProfile(target.directory)
                    try Task.checkCancellation()
                    guard let self else { return }
                    if target != profile || dataStore == nil {
                        if let dataStore { drain(dataStore) }
                        closeAllTabs(); closedTabs = []; pendingSeeds = [:]
                        dataStore = WKWebsiteDataStore.nonPersistent()
                    }
                    guard !stopped, remote.hasLiveLease, let dataStore else {
                        throw ExtensionPeerError.unavailable
                    }
                    session = descriptor.session
                    syncState = .importing("Importing \(snapshot.cookies.count) cookies")
                    let applied = await ChromeProfileImporter.apply(
                        snapshot.cookies, to: dataStore.httpCookieStore)
                    guard !Task.isCancelled, !stopped, remote.hasLiveLease,
                        self.dataStore === dataStore
                    else {
                        drain(dataStore)
                        throw CancellationError()
                    }
                    finishInstall(target, snapshot: snapshot, applied: applied, readStorage: true)
                } catch {
                    if !Task.isCancelled { self?.syncState = .failed(error.localizedDescription) }
                }
            }
            return
        }
        syncTask?.cancel()
        syncState = cookieKey == nil ? .unlocking : .importing("Reading \(target.name)")
        let userData = installation.userData
        let keyProvider = keyProvider
        let cachedKey = cookieKey
        let since = full || target != profile ? nil : cookieWatermark
        syncTask = Task { [weak self] in
            let outcome = await Self.read(
                target, userData: userData, key: cachedKey, keyProvider: keyProvider, since: since)
            guard !Task.isCancelled else { return }
            self?.install(target, outcome: outcome, readStorage: since == nil)
        }
    }

    nonisolated private static func read(
        _ profile: ChromeProfile, userData: ChromeUserData, key cachedKey: ChromeCookieKey?,
        keyProvider: @escaping @Sendable () throws -> ChromeCookieKey, since: Date?
    ) async -> Result<(ChromeCookieKey, ChromeProfileSnapshot), Error> {
        await Task.detached(priority: .userInitiated) {
            Result {
                let key = try cachedKey ?? keyProvider()
                let snapshot = try ChromeProfileImporter.snapshot(
                    profile: profile, userData: userData, key: key,
                    cookiesUpdatedAfter: since, includeLocalStorage: since == nil)
                return (key, snapshot)
            }
        }.value
    }

    private func install(
        _ target: ChromeProfile,
        outcome: Result<(ChromeCookieKey, ChromeProfileSnapshot), Error>, readStorage: Bool
    ) {
        switch outcome {
        case .failure(let error):
            syncState = .failed(error.localizedDescription)
        case .success(let (key, snapshot)):
            cookieKey = key
            if target != profile {
                closeAllTabs()
                closedTabs = []
                pendingSeeds = [:]
                dataStore = dataStoreFactory(
                    ChromeProfileImporter.dataStoreIdentifier(
                        profile: target, userData: installation.userData))
            }
            guard let dataStore else { return }
            syncState = .importing("Importing \(snapshot.cookies.count) cookies")
            syncTask?.cancel()
            syncTask = Task { [weak self] in
                let applied = await ChromeProfileImporter.apply(
                    snapshot.cookies, to: dataStore.httpCookieStore)
                guard !Task.isCancelled else { return }
                self?.finishInstall(
                    target, snapshot: snapshot, applied: applied, readStorage: readStorage)
            }
        }
    }

    private func finishInstall(
        _ target: ChromeProfile, snapshot: ChromeProfileSnapshot, applied: Int, readStorage: Bool
    ) {
        if readStorage { pendingSeeds = snapshot.localStorage }
        cookieWatermark = snapshot.newestCookieUpdate ?? cookieWatermark
        lastSync = Date()
        let attaching = profile != target
        profile = target
        choosingProfile = false
        syncState = .idle
        syncSummary = Self.summary(applied: applied, snapshot: snapshot)
        session.profile = target.directory
        session.profileName = target.name
        persistSession()
        if tabs.isEmpty { restoreTabs() }
        guard attaching else { return }
        showToast("Attached \(target.name)")
        onProfileChange?()
    }

    nonisolated static func summary(applied: Int, snapshot: ChromeProfileSnapshot) -> String {
        let cookies = applied == 1 ? "1 cookie" : "\(applied) cookies"
        let sites = snapshot.siteCount == 1 ? "1 site" : "\(snapshot.siteCount) sites"
        guard !snapshot.localStorage.isEmpty else { return "\(cookies) from \(sites)" }
        return "\(cookies) from \(sites), local storage for \(snapshot.localStorage.count)"
    }

    private func restoreTabs() {
        guard dataStore != nil, tabs.isEmpty else { return }
        let urls = session.restorableURLs
        guard !urls.isEmpty else {
            newTab(searchEngine.home)
            return
        }
        let selected = session.selected
        restoring = true
        for url in urls { newTab(url, select: false) }
        restoring = false
        selectedTabID = tabs[min(max(selected, 0), tabs.count - 1)].id
        session.tabs = urls.map(\.absoluteString)
        session.selected = min(max(selected, 0), tabs.count - 1)
        persistSession()
    }

    @discardableResult
    func newTab(
        _ url: URL? = nil, after anchor: BrowserTab? = nil, select: Bool = true,
        configuration: WKWebViewConfiguration? = nil
    ) -> BrowserTab? {
        guard permitsNativeNavigation, tabs.count < 128, let dataStore,
            url.map({ Self.permittedURL($0, remote: remote != nil) }) ?? true,
            configuration.map({ $0.websiteDataStore === dataStore }) ?? true
        else { return nil }
        let webView = NotchWebView(
            frame: .zero, configuration: configuration ?? makeConfiguration(dataStore))
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        let tab = BrowserTab(webView: webView)
        let index =
            anchor.flatMap { anchor in tabs.firstIndex { $0.id == anchor.id } }.map { $0 + 1 }
            ?? tabs.count
        tabs.insert(tab, at: min(index, tabs.count))
        if select || selectedTabID == nil { selectedTabID = tab.id }
        if let url {
            webView.load(URLRequest(url: url))
        } else if configuration == nil {
            webView.load(URLRequest(url: searchEngine.home))
            if select { focusAddress() }
        }
        saveSession()
        return tab
    }

    func makeConfiguration(_ store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = Self.userAgentSuffix
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            NotchBrowserScriptProxy(store: self), name: LocalStorageSeed.messageName)
        contentControllers[ObjectIdentifier(configuration.userContentController)] =
            configuration.userContentController
        return configuration
    }

    static let userAgentSuffix: String = {
        let safari = Bundle(path: "/Applications/Safari.app")
        let version =
            safari?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    func select(_ tab: BrowserTab) {
        guard selectedTabID != tab.id else { return }
        selectedTabID = tab.id
        saveSession()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func selectRelative(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = ((current + offset) % tabs.count + tabs.count) % tabs.count
        select(tabs[next])
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let url = tab.url, BrowserTab.origin(of: url) != nil {
            closedTabs.append(url)
            if closedTabs.count > Self.closedTabLimit { closedTabs.removeFirst() }
        }
        faviconTasks.removeValue(forKey: tab.id)?.cancel()
        retire(tab)
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { newTab() }
        saveSession()
    }

    func closeOthers(_ tab: BrowserTab) {
        for other in tabs where other.id != tab.id { close(other) }
    }

    func closeToRight(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for other in tabs.suffix(from: index + 1) { close(other) }
    }

    func reopenClosedTab() {
        guard let url = closedTabs.popLast() else { return }
        newTab(url, after: selectedTab)
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    func duplicate(_ tab: BrowserTab) {
        newTab(tab.url, after: tab)
    }

    func move(_ tab: BrowserTab, to destination: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = min(max(destination, 0), tabs.count - 1)
        guard target != index else { return }
        tabs.remove(at: index)
        tabs.insert(tab, at: target)
        saveSession()
    }

    func submitAddress(_ text: String) {
        guard permitsNativeNavigation,
            let url = BrowserAddress.url(for: text, engine: searchEngine),
            Self.permittedURL(url, remote: remote != nil)
        else { return }
        if let tab = selectedTab {
            tab.webView.load(URLRequest(url: url))
        } else {
            newTab(url)
        }
    }

    func openInChrome(_ tab: BrowserTab?) {
        guard let url = (tab ?? selectedTab)?.url else { return }
        if let remote { remote.perform(.openInChrome) { $0.link = url.absoluteString }; return }
        installation.open(url, profile: profile)
    }

    func copyLink(_ tab: BrowserTab) {
        guard let url = tab.url else { return }
        if let remote {
            remote.perform(
                .copyLink, configure: { $0.link = url.absoluteString },
                completion: { [weak self] in self?.showToast("Link copied") });
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showToast("Link copied")
    }

    func focusAddress() {
        requestKeyFocus?()
        addressFocusRequest += 1
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard
            let shortcut = BrowserShortcut.match(
                characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
        else { return false }
        if let action = shortcut.editAction { return NSApp.sendAction(action, to: nil, from: nil) }
        perform(shortcut)
        return true
    }

    func perform(_ shortcut: BrowserShortcut) {
        let webView = selectedTab?.webView
        switch shortcut {
        case .newTab: newTab()
        case .closeTab: if let tab = selectedTab { close(tab) }
        case .reopenClosedTab: reopenClosedTab()
        case .focusAddress: focusAddress()
        case .reload: webView?.reload()
        case .hardReload: webView?.reloadFromOrigin()
        case .back: webView?.goBack()
        case .forward: webView?.goForward()
        case .nextTab: selectRelative(1)
        case .previousTab: selectRelative(-1)
        case .selectTab(let index): selectTab(at: index)
        case .lastTab: selectTab(at: tabs.count - 1)
        case .zoomIn: webView?.pageZoom = Self.zoom((webView?.pageZoom ?? 1) + 0.1)
        case .zoomOut: webView?.pageZoom = Self.zoom((webView?.pageZoom ?? 1) - 0.1)
        case .zoomReset: webView?.pageZoom = 1
        case .copy, .cut, .paste, .selectAll, .undo, .redo: break
        }
    }

    nonisolated static func zoom(_ value: CGFloat) -> CGFloat {
        min(3, max(0.3, (value * 10).rounded() / 10))
    }

    func beginResize(_ edge: NotchBrowserResizeEdge) {
        resizeStart = (size, NSEvent.mouseLocation, edge)
        isResizing = true
    }

    func updateResize() {
        guard let start = resizeStart else { return }
        applySize(
            NotchBrowserGeometry.resized(
                from: start.size, edge: start.edge, pointerStart: start.pointer,
                pointer: NSEvent.mouseLocation, screen: screenSize()))
    }

    func endResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        isResizing = false
        saveSession()
    }

    func applySize(_ next: CGSize) {
        let clamped = NotchBrowserGeometry.clamp(next, screen: screenSize())
        guard clamped != size else { return }
        size = clamped
        if remote != nil { saveSession() }
        onSizeChange?()
    }

    func resetSize() {
        applySize(NotchBrowserGeometry.defaultSize)
        saveSession()
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }

    func policy(for action: WKNavigationAction, in webView: WKWebView) -> WKNavigationActionPolicy {
        guard permitsNativeNavigation, tab(for: webView) != nil else { return .cancel }
        guard let url = action.request.url else { return .cancel }
        guard Self.permittedURL(url, remote: remote != nil) else { return .cancel }
        if action.shouldPerformDownload { return .download }
        let wantsNewTab =
            action.navigationType == .linkActivated
            && (action.modifierFlags.contains(.command) || action.buttonNumber == 2)
        if wantsNewTab, action.targetFrame?.isMainFrame != false {
            newTab(
                url, after: tab(for: webView), select: action.modifierFlags.contains(.shift))
            return .cancel
        }
        if action.targetFrame?.isMainFrame == true { prepareSeed(for: url, in: webView) }
        return .allow
    }

    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file"]

    static func permittedURL(_ url: URL, remote: Bool) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if remote {
            return ["http", "https", "data", "blob"].contains(scheme)
                || url.absoluteString == "about:blank"
        }
        return webSchemes.contains(scheme)
    }

    static func responsePolicy(_ response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        let disposition =
            (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") { return .download }
        return response.canShowMIMEType ? .allow : .download
    }

    func prepareSeed(for url: URL, in webView: WKWebView) {
        guard let origin = BrowserTab.origin(of: url), let items = pendingSeeds[origin],
            let source = LocalStorageSeed.script(origin: origin, items: items)
        else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func seedApplied(origin: String, in webView: WKWebView?) {
        pendingSeeds[origin] = nil
        webView?.configuration.userContentController.removeAllUserScripts()
    }

    func popup(configuration: WKWebViewConfiguration, from webView: WKWebView) -> WKWebView? {
        newTab(nil, after: tab(for: webView), select: true, configuration: configuration)?.webView
    }

    func closeTab(for webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        close(tab)
    }

    func pageFinished(_ webView: WKWebView) {
        guard permitsNativeNavigation, let tab = tab(for: webView) else { return }
        loadFavicon(for: tab)
        saveSession()
    }

    func present(_ kind: BrowserDialog.Kind, message: String, frame: WKFrameInfo) async -> (
        Bool, String?
    ) {
        guard permitsNativeNavigation, dialog == nil else { return (false, nil) }
        return await withCheckedContinuation { continuation in
            dialog = BrowserDialog(
                kind: kind, host: frame.securityOrigin.host, message: message,
                resolve: { [weak self] accepted, text in
                    self?.dialog = nil
                    continuation.resume(returning: (accepted, text))
                })
        }
    }

    func chooseFiles(_ parameters: WKOpenPanelParameters, window: NSWindow?) async -> [URL]? {
        guard permitsNativeNavigation, !NotchWorkerPresentation.isTesting else { return nil }
        filePanelOpen = true
        defer { filePanelOpen = false }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let previous = NSWorkspace.shared.frontmostApplication
        NotchWorkerPresentation.activate(ignoringOtherApps: false)
        let response = await panel.begin()
        if let previous, previous != NSRunningApplication.current { previous.activate() }
        NotchWorkerPresentation.makeKey(window)
        return response == .OK ? panel.urls : nil
    }

    func downloadDestination(for download: WKDownload, suggestedFilename: String) async -> URL? {
        guard permitsNativeNavigation else { return nil }
        nativeDownloads[ObjectIdentifier(download)] = download
        if let remote {
            guard remoteDownloads.count + deliveries.count < 8 else {
                showToast("The download capacity has been reached."); return nil
            }
            do {
                let descriptor = try await remote.beginDownload(suggestedFilename)
                guard permitsNativeNavigation, !Task.isCancelled else {
                    await remote.cancelDownload(descriptor)
                    return nil
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "notch-download-" + descriptor.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let url = folder.appendingPathComponent("payload")
                remoteDownloads[ObjectIdentifier(download)] = (descriptor, url)
                showToast("Downloading \(descriptor.name)")
                return url
            } catch { showToast(error.localizedDescription); return nil }
        }
        let folder =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let destination = Self.uniqueDestination(
            in: folder, filename: suggestedFilename,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        downloads[ObjectIdentifier(download)] = destination
        showToast("Downloading \(destination.lastPathComponent)")
        return destination
    }

    nonisolated static func uniqueDestination(
        in folder: URL, filename: String, exists: (URL) -> Bool
    ) -> URL {
        let cleaned = filename.replacingOccurrences(of: "/", with: "-")
        let name = cleaned.isEmpty ? "download" : cleaned
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 1
        while exists(candidate) {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    func downloadFinished(_ download: WKDownload) {
        nativeDownloads[ObjectIdentifier(download)] = nil
        if let remote,
            let (descriptor, url) = remoteDownloads.removeValue(forKey: ObjectIdentifier(download))
        {
            deliveries[descriptor.id] = Task { [weak self] in
                defer {
                    self?.deliveries[descriptor.id] = nil;
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
                do {
                    let name = try await remote.publishDownload(descriptor, file: url);
                    self?.showToast("Downloaded \(name)")
                } catch { if !Task.isCancelled { self?.showToast(error.localizedDescription) } }
            }
            return
        }
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: url.path)
        showToast("Downloaded \(url.lastPathComponent)")
    }

    func downloadFailed(_ download: WKDownload) {
        nativeDownloads[ObjectIdentifier(download)] = nil
        if let remote,
            let (descriptor, url) = remoteDownloads.removeValue(forKey: ObjectIdentifier(download))
        {
            deliveries[descriptor.id] = Task { [weak self] in
                await remote.cancelDownload(descriptor)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                self?.deliveries[descriptor.id] = nil
            }
        }
        downloads[ObjectIdentifier(download)] = nil
        showToast("Download failed")
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func loadFavicon(for tab: BrowserTab) {
        guard permitsNativeNavigation, !NotchWorkerPresentation.isTesting else { return }
        guard let url = tab.url, let host = url.host() else { return }
        if let cached = faviconCache[host] {
            tab.favicon = cached
            return
        }
        faviconTasks[tab.id]?.cancel()
        let webView = tab.webView
        faviconTasks[tab.id] = Task { [weak self, weak tab] in
            let href = await Self.faviconHref(in: webView)
            guard !Task.isCancelled, let self, permitsNativeNavigation else { return }
            let fallback = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL
            guard let iconURL = href.flatMap({ URL(string: $0) }) ?? fallback,
                Self.permittedURL(iconURL, remote: remote != nil),
                let (data, _) = try? await faviconSession.data(from: iconURL), data.count <= 262144
            else { return }
            guard !Task.isCancelled, let image = NSImage(data: data) else { return }
            faviconCache[host] = image
            tab?.favicon = image
        }
    }

    private static let faviconScript = """
        (function () {
        var link = document.querySelector('link[rel~="icon"], link[rel="apple-touch-icon"]');
        return link && link.href ? link.href : "";
        })();
        """

    private static func faviconHref(in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(faviconScript) { result, _ in
                let href = result as? String
                continuation.resume(returning: href?.isEmpty == false ? href : nil)
            }
        }
    }

    private func closeAllTabs() {
        dialog?.resolve(false, nil)
        for task in faviconTasks.values { task.cancel() }
        faviconTasks = [:]
        for tab in tabs { retire(tab) }
        tabs = []
        selectedTabID = nil
    }

    private func retire(_ tab: BrowserTab) {
        let controller = tab.webView.configuration.userContentController
        if !tabs.contains(where: {
            $0.id != tab.id && $0.webView.configuration.userContentController === controller
        }) {
            controller.removeAllUserScripts()
            controller.removeScriptMessageHandler(forName: LocalStorageSeed.messageName)
            contentControllers[ObjectIdentifier(controller)] = nil
        }
        let task = tab.close()
        let id = UUID()
        storeDrains[id] = Task { await task.value }
    }

    private func saveSession() {
        guard !restoring else { return }
        session.tabs = tabs.compactMap { tab in
            tab.url.flatMap { BrowserTab.origin(of: $0) != nil ? $0.absoluteString : nil }
        }
        session.selected = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        session.width = Double(size.width)
        session.height = Double(size.height)
        persistSession()
    }

    private func persistSession() {
        if let remote { remote.save(session) } else { sessionFile.save(session) }
    }

    func applyRemoteState(_ state: NotchBrowserClientState) {
        readiness = state.readiness
        profiles = state.profiles
        ChromeProfileAvatar.installRemote(state.avatars)
        if tabs.isEmpty, syncState == .idle {
            session = state.session
            profile = profiles.first { $0.directory == state.session.profile }
        }
    }

    private func observeMenus() {
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuDepth += 1 }
            },
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth - 1)
                }
            },
        ]
    }
}
