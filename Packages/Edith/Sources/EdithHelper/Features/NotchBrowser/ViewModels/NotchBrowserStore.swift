import AppKit
import EdithKit
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
    private(set) var syncState: SyncState = .idle
    private(set) var syncSummary: String?
    private(set) var size: CGSize
    private(set) var isResizing = false
    private(set) var menuDepth = 0
    private(set) var filePanelOpen = false
    private(set) var dialog: BrowserDialog?
    private(set) var toast: String?
    private(set) var addressFocusRequest = 0
    private(set) var choosingProfile = false

    @ObservationIgnored var screenSize: () -> CGSize? = { nil }
    @ObservationIgnored var onSizeChange: (() -> Void)?
    @ObservationIgnored var requestKeyFocus: (() -> Void)?
    @ObservationIgnored private let sessionFile: BrowserSessionFile
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyProvider: @Sendable () throws -> ChromeCookieKey
    @ObservationIgnored private let dataStoreFactory: @MainActor (UUID) -> WKWebsiteDataStore
    @ObservationIgnored private var session: BrowserSession
    @ObservationIgnored private var dataStore: WKWebsiteDataStore?
    @ObservationIgnored private var cookieKey: ChromeCookieKey?
    @ObservationIgnored private var cookieWatermark: Date?
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private(set) var pendingSeeds: [String: [String: String]] = [:]
    @ObservationIgnored private var closedTabs: [URL] = []
    @ObservationIgnored private var downloads: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var faviconCache: [String: NSImage] = [:]
    @ObservationIgnored private var faviconTasks: [BrowserTab.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var resizeStart:
        (size: CGSize, pointer: CGPoint, edge: NotchBrowserResizeEdge)?
    @ObservationIgnored private var menuObservers: [NSObjectProtocol] = []
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
        }
    ) {
        self.installation = installation
        self.sessionFile = sessionFile
        self.defaults = defaults
        self.keyProvider = keyProvider
        self.dataStoreFactory = dataStoreFactory
        session = sessionFile.load()
        size = NotchBrowserGeometry.clamp(
            session.size ?? NotchBrowserGeometry.defaultSize, screen: nil)
        refreshEnvironment()
        if let directory = session.profile,
            let saved = profiles.first(where: { $0.directory == directory })
        {
            profile = saved
            dataStore = dataStoreFactory(
                ChromeProfileImporter.dataStoreIdentifier(
                    profile: saved, userData: installation.userData))
        }
        observeMenus()
    }

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }

    var holdsOpen: Bool {
        isResizing || menuDepth > 0 || filePanelOpen || dialog != nil || syncState == .unlocking
    }

    var showsSetup: Bool { profile == nil || choosingProfile }

    var searchEngine: BrowserSearchEngine {
        BrowserSearchEngine(
            rawValue: defaults.string(forKey: AppStorageKeys.Notch.browserSearchEngine) ?? "")
            ?? .google
    }

    func shutdown() {
        syncTask?.cancel()
        toastTask?.cancel()
        dialog?.resolve(false, nil)
        dialog = nil
        saveSession()
        closeAllTabs()
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers = []
    }

    func refreshEnvironment() {
        let inspection = installation.inspect()
        readiness = inspection.readiness
        profiles = inspection.profiles
    }

    func appeared() {
        guard let profile, !choosingProfile else {
            refreshEnvironment()
            return
        }
        if tabs.isEmpty { restoreTabs() }
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
        installation.makeDefaultBrowser { [weak self] _ in self?.refreshEnvironment() }
    }

    func downloadChrome() {
        NSWorkspace.shared.open(ChromeInstallation.downloadURL)
    }

    func attach(_ chosen: ChromeProfile) {
        load(chosen, full: true)
    }

    func syncNow() {
        guard let profile else { return }
        load(profile, full: true)
    }

    func detach() {
        syncTask?.cancel()
        syncState = .idle
        syncSummary = nil
        closeAllTabs()
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
        session.tabs = []
        session.selected = 0
        sessionFile.save(session)
        refreshEnvironment()
        guard let released, let identifier else { return }
        released.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) {
            WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in }
        }
    }

    private func load(_ target: ChromeProfile, full: Bool) {
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
            self?.install(target, outcome: outcome)
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
        outcome: Result<(ChromeCookieKey, ChromeProfileSnapshot), Error>
    ) {
        switch outcome {
        case .failure(let error):
            syncState = .failed(error.localizedDescription)
        case .success(let (key, snapshot)):
            cookieKey = key
            if target != profile {
                closeAllTabs()
                closedTabs = []
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
                self?.finishInstall(target, snapshot: snapshot, applied: applied)
            }
        }
    }

    private func finishInstall(
        _ target: ChromeProfile, snapshot: ChromeProfileSnapshot, applied: Int
    ) {
        if !snapshot.localStorage.isEmpty { pendingSeeds = snapshot.localStorage }
        cookieWatermark = snapshot.newestCookieUpdate ?? cookieWatermark
        lastSync = Date()
        let attaching = profile != target
        profile = target
        choosingProfile = false
        syncState = .idle
        syncSummary = Self.summary(applied: applied, snapshot: snapshot)
        session.profile = target.directory
        sessionFile.save(session)
        if tabs.isEmpty { restoreTabs() }
        if attaching { showToast("Attached \(target.name)") }
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
        for url in urls { newTab(url, select: false) }
        selectedTabID = tabs[min(max(session.selected, 0), tabs.count - 1)].id
    }

    @discardableResult
    func newTab(
        _ url: URL? = nil, after anchor: BrowserTab? = nil, select: Bool = true,
        configuration: WKWebViewConfiguration? = nil
    ) -> BrowserTab? {
        guard let dataStore else { return nil }
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
        tab.close()
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
        guard let url = BrowserAddress.url(for: text, engine: searchEngine) else { return }
        if let tab = selectedTab {
            tab.webView.load(URLRequest(url: url))
        } else {
            newTab(url)
        }
    }

    func openInChrome(_ tab: BrowserTab?) {
        guard let url = (tab ?? selectedTab)?.url else { return }
        installation.open(url, profile: profile)
    }

    func copyLink(_ tab: BrowserTab) {
        guard let url = tab.url else { return }
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
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""
        guard Self.webSchemes.contains(scheme) else {
            NSWorkspace.shared.open(url)
            return .cancel
        }
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
        guard let tab = tab(for: webView) else { return }
        loadFavicon(for: tab)
        saveSession()
    }

    func present(_ kind: BrowserDialog.Kind, message: String, frame: WKFrameInfo) async -> (
        Bool, String?
    ) {
        guard dialog == nil else { return (false, nil) }
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
        filePanelOpen = true
        defer { filePanelOpen = false }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let response = await panel.begin()
        if let previous, previous != NSRunningApplication.current { previous.activate() }
        window?.makeKey()
        return response == .OK ? panel.urls : nil
    }

    func downloadDestination(for download: WKDownload, suggestedFilename: String) -> URL? {
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
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: url.path)
        showToast("Downloaded \(url.lastPathComponent)")
    }

    func downloadFailed(_ download: WKDownload) {
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
        guard let url = tab.url, let host = url.host() else { return }
        if let cached = faviconCache[host] {
            tab.favicon = cached
            return
        }
        faviconTasks[tab.id]?.cancel()
        let webView = tab.webView
        faviconTasks[tab.id] = Task { [weak self, weak tab] in
            let href = await Self.faviconHref(in: webView)
            guard !Task.isCancelled else { return }
            let fallback = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL
            guard let iconURL = href.flatMap({ URL(string: $0) }) ?? fallback,
                let (data, _) = try? await Self.faviconSession.data(from: iconURL)
            else { return }
            guard !Task.isCancelled, let image = NSImage(data: data) else { return }
            self?.faviconCache[host] = image
            tab?.favicon = image
        }
    }

    private static let faviconSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

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
        for tab in tabs { tab.close() }
        tabs = []
        selectedTabID = nil
    }

    private func saveSession() {
        session.tabs = tabs.compactMap { tab in
            tab.url.flatMap { BrowserTab.origin(of: $0) != nil ? $0.absoluteString : nil }
        }
        session.selected = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        session.width = Double(size.width)
        session.height = Double(size.height)
        sessionFile.save(session)
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
