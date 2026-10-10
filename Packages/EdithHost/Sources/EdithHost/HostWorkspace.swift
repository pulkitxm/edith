import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostWorkspace: View {
    let marketplace: HostMarketplace
    let updater: HostUpdater
    var showWelcome: (() -> Void)? = nil
    var panelShortcutChanged: () -> Void = {}
    var additionalSettings: ((String) -> AnyView?)? = nil
    var coreOnline = false
    var coreSummary = "Not running"
    @State private var permissions = HostPermissions()
    var presenter: (any HostExtensionContentPresenting)? = nil
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var selection = "home"
    @AppStorage(AppStorageKeys.General.settingsTab, store: SharedDefaults.store) private
        var settings = "general"
    @AppStorage(AppStorageKeys.General.mainSidebarOpen, store: SharedDefaults.store) private
        var sidebarOpen = true
    @AppStorage(AppStorageKeys.General.mainSidebarWidth, store: SharedDefaults.store) private
        var sidebarWidth = 230.0
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.General.creditHidden, store: SharedDefaults.store) private
        var creditHidden = false
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0
    @AppStorage(AppStorageKeys.AppMaintenance.section, store: SharedDefaults.store) private
        var maintenanceSection = "Updates"
    @State private var router = WindowRouter()
    @State private var expansionRevision = 0
    @State private var liveSidebarWidth: Double?
    @State private var dragBaseWidth: Double?
    @State private var keyMonitor: Any?
    @State private var hintMonitor: Any?
    @State private var showHints = false
    @State private var fullscreen = false
    @Environment(\.automaticViewActionsEnabled) private var automaticActions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let navigationDefaults: UserDefaults
    init(
        marketplace: HostMarketplace, presenter: (any HostExtensionContentPresenting)? = nil,
        updater: HostUpdater? = nil, showWelcome: (() -> Void)? = nil,
        panelShortcutChanged: @escaping () -> Void = {},
        additionalSettings: ((String) -> AnyView?)? = nil,
        coreOnline: Bool = false, coreSummary: String = "Not running",
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.marketplace = marketplace
        self.updater = updater ?? HostUpdater(startingUpdater: false)
        self.showWelcome = showWelcome; self.panelShortcutChanged = panelShortcutChanged
        self.additionalSettings = additionalSettings
        self.coreOnline = coreOnline; self.coreSummary = coreSummary
        self.presenter = presenter
        navigationDefaults = defaults
        _selection = AppStorage(
            wrappedValue: "home", AppStorageKeys.General.mainWindowSection, store: defaults)
        _settings = AppStorage(
            wrappedValue: "general", AppStorageKeys.General.settingsTab, store: defaults)
        _sidebarOpen = AppStorage(
            wrappedValue: true, AppStorageKeys.General.mainSidebarOpen, store: defaults)
        _sidebarWidth = AppStorage(
            wrappedValue: 230, AppStorageKeys.General.mainSidebarWidth, store: defaults)
        _themeName = AppStorage(
            wrappedValue: "accent", AppStorageKeys.General.theme, store: defaults)
        _creditHidden = AppStorage(
            wrappedValue: false, AppStorageKeys.General.creditHidden, store: defaults)
        _zoom = AppStorage(wrappedValue: 1, WindowZoom.defaultsKey, store: defaults)
        _maintenanceSection = AppStorage(
            wrappedValue: "Updates", AppStorageKeys.AppMaintenance.section, store: defaults)
    }
    private var defaults: UserDefaults { navigationDefaults }
    private var active: Set<String> { marketplace.surfaceAvailability.activeIDs }
    private var destination: HostNavigationPage {
        HostNavigationCatalog.page(
            HostNavigationCatalog.resolve(selection, active: active, defaults: defaults))
    }
    private var theme: Color { themeColor(themeName) }
    private var width: Double { UIScale.pt(min(320, max(180, liveSidebarWidth ?? sidebarWidth))) }
    private var pages: [HostNavigationPage] {
        HostNavigationCatalog.pages.filter {
            HostNavigationCatalog.visible($0, active: active, defaults: defaults)
        }
    }
    private var binding: Binding<String> {
        Binding(
            get: { destination.id },
            set: {
                selection = HostNavigationCatalog.resolve($0, active: active, defaults: defaults)
            })
    }

    var body: some View {
        NavigationRouteHost(router: router, role: .main) {
            ZStack(alignment: .topLeading) {
                sidebar.frame(width: width).frame(
                    maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                detailColumn
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: sidebarOpen ? 12 : 0,
                            bottomLeadingRadius: sidebarOpen ? 12 : 0)
                    )
                    .padding(.leading, sidebarOpen ? width : 0)
                    .shadow(
                        color: scheme == .dark ? .black.opacity(0.55) : .black.opacity(0.16),
                        radius: UIScale.pt(18), x: -6, y: 0)
                sidebarEdge.offset(x: sidebarOpen ? width : 0).opacity(sidebarOpen ? 1 : 0)
                titlebar.padding(.leading, UIScale.pt(fullscreen ? 12 : 94))
            }
            .ignoresSafeArea()
            .animation(
                Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: sidebarOpen
            )
            .navigationRoute(
                "section", selection: binding,
                isValid: { raw in raw.isEmpty || pages.contains { $0.id == raw } })
        }
        .background(HostWindowChrome(persist: automaticActions, fullscreen: $fullscreen))
        .onAppear { installKeys() }
        .onDisappear { removeKeys() }
        .onExitCommand { NSApp.keyWindow?.makeFirstResponder(nil) }
        .onChange(of: marketplace.surfaces.navigation.editorRequest, initial: true) {
            guard let request = marketplace.surfaces.navigation.editorRequest else { return }
            defaults.set(request.target.rawValue, forKey: HostSurfaceEditorKeys.target)
            defaults.set(request.tileID ?? "", forKey: HostSurfaceEditorKeys.widget)
            customize()
        }
    }
    private var titlebar: some View {
        HStack(spacing: 14) {
            Button {
                sidebarOpen.toggle()
            } label: {
                Image(systemName: "sidebar.left").font(
                    .system(size: UIScale.pt(15), weight: .medium)
                )
                .foregroundStyle(.secondary).frame(width: UIScale.pt(22), height: UIScale.pt(22))
            }.buttonStyle(.edith(.toolbar)).help("Toggle sidebar (⌘B)").keyboardShortcut(
                "b", modifiers: .command
            ).accessibilityLabel("Toggle sidebar")
            if sidebarOpen, width - UIScale.pt(fullscreen ? 12 : 94) >= UIScale.pt(130) {
                HStack(spacing: 6) {
                    if let icon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: icon).resizable().frame(
                            width: UIScale.pt(17), height: UIScale.pt(17))
                    }
                    Text("Edith").font(.system(size: UIScale.pt(13), weight: .medium)).tracking(
                        -0.2
                    ).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.frame(
            width: sidebarOpen
                ? max(width - UIScale.pt(fullscreen ? 12 : 94), UIScale.pt(60)) : UIScale.pt(200),
            height: UIScale.pt(31)
        ).clipped()
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: UIScale.pt(41))
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(pages.filter { $0.parentID == nil }) { page in
                        if page.id == "extensions" {
                            Text("App").font(.system(size: UIScale.pt(11), weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, UIScale.pt(8)).padding(.top, UIScale.pt(14))
                                .padding(.bottom, UIScale.pt(4))
                        }
                        row(page)
                        if expanded(page) {
                            ForEach(
                                page.sections.filter {
                                    page.id == "settings"
                                        || $0.extensionID.map(active.contains) ?? true
                                }
                            ) { section in sectionRow(section, parent: page) }
                            ForEach(pages.filter { $0.parentID == page.id }) { child in row(child) }
                        }
                    }
                }.padding(.horizontal, UIScale.pt(8)).padding(.top, UIScale.pt(8))
            }
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: UIScale.pt(1))
            HostSidebarFooter(
                marketplace: marketplace, updater: updater, permissions: permissions,
                theme: theme, sidebarWidth: liveSidebarWidth ?? sidebarWidth, presenter: presenter,
                openExtensions: { selection = "extensions" },
                openPermissions: {
                    settings = "permissions"; selection = "settings"
                }, enabled: sidebarOpen)
            HostAgentStatusBar(online: coreOnline, summary: coreSummary) {
                settings = "agent"; selection = "settings"
            }
            if !creditHidden {
                HStack(spacing: UIScale.pt(3)) {
                    Spacer(minLength: 0)
                    Text("Made with ♥ by").foregroundStyle(.tertiary)
                    Button("Pulkit") {
                        NSWorkspace.shared.open(URL(string: "https://pulkit.page")!)
                    }.buttonStyle(.edith(.borderless)).fontWeight(.semibold).foregroundStyle(theme)
                    Spacer(minLength: 0)
                    Button {
                        creditHidden = true
                    } label: {
                        Image(systemName: "xmark").font(
                            .system(size: UIScale.pt(8), weight: .semibold)
                        ).frame(width: UIScale.pt(16), height: UIScale.pt(16))
                    }.buttonStyle(.edith(.toolbar)).help("Hide this")
                }.font(.system(size: UIScale.pt(10))).padding(.horizontal, UIScale.pt(8)).padding(
                    .bottom, UIScale.pt(8))
            }
        }
    }
    private func expanded(_ page: HostNavigationPage) -> Bool {
        _ = expansionRevision; return HostNavigationCatalog.expanded(page, defaults: defaults)
    }
    private func toggle(_ page: HostNavigationPage) {
        guard let key = HostNavigationCatalog.expansionKey(page) else { return };
        defaults.set(!expanded(page), forKey: key); expansionRevision += 1
    }
    private func row(_ page: HostNavigationPage) -> some View {
        let expandable = !page.sections.isEmpty || pages.contains { $0.parentID == page.id }
        return ZStack(alignment: .trailing) {
            Button {
                if expandable, destination.id == page.id {
                    toggle(page)
                } else {
                    selection = page.id
                }
            } label: {
                HStack(spacing: UIScale.pt(11)) {
                    Image(systemName: page.symbol).font(
                        .system(size: UIScale.pt(15), weight: .medium)
                    ).foregroundStyle(destination.id == page.id ? .primary : .secondary).frame(
                        width: UIScale.pt(22))
                    Text(page.title).font(
                        .system(size: UIScale.pt(13.5), weight: page.landing ? .semibold : .medium)
                    ).foregroundStyle(
                        destination.id == page.id || page.landing ? .primary : .secondary
                    ).lineLimit(1)
                    Spacer(minLength: 0)
                    if showHints, let index = pages.firstIndex(of: page), index < 8 {
                        Text("⌥\(index + 1)").font(.system(size: UIScale.pt(11), weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    if expandable { Color.clear.frame(width: UIScale.pt(28)) }
                }
            }.buttonStyle(EdithButtonStyle(.row, selected: destination.id == page.id, tint: theme))
                .padding(.leading, page.parentID == nil ? 0 : UIScale.pt(18))
                .accessibilityValue(expandable ? (expanded(page) ? "Expanded" : "Collapsed") : "")
            if expandable {
                Button {
                    toggle(page)
                } label: {
                    Image(systemName: "chevron.right").font(
                        .system(size: UIScale.pt(10), weight: .semibold)
                    ).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded(page) ? 90 : 0))
                        .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                }.buttonStyle(.edith(.borderless)).padding(.trailing, UIScale.pt(2))
                    .accessibilityLabel(
                        (expanded(page) ? "Collapse " : "Expand ") + page.title + " abilities")
            }
        }
    }
    private func sectionRow(_ section: HostNavigationSection, parent: HostNavigationPage)
        -> some View
    {
        Button {
            selection = parent.id
            if parent.id == "settings" {
                settings = section.id
            } else {
                maintenanceSection = section.id
            }
        } label: {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: section.symbol).frame(width: UIScale.pt(18));
                Text(section.title).lineLimit(1); Spacer(minLength: 0)
            }.font(.system(size: UIScale.pt(12.5), weight: .medium)).foregroundStyle(
                destination.id == parent.id ? .primary : .secondary)
        }.buttonStyle(
            EdithButtonStyle(
                .row,
                selected: destination.id == parent.id
                    && (parent.id == "settings" ? settings : maintenanceSection) == section.id,
                tint: theme)
        ).padding(.leading, UIScale.pt(18))
    }
    private var sidebarEdge: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: UIScale.pt(1)).overlay {
            Color.clear.frame(width: UIScale.pt(9)).contentShape(Rectangle()).onHover {
                if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global).onChanged { value in
                    let base = dragBaseWidth ?? width; dragBaseWidth = base
                    liveSidebarWidth = min(
                        320, max(180, (base + value.translation.width) / UIScale.current))
                }.onEnded { _ in
                    if let liveSidebarWidth { sidebarWidth = liveSidebarWidth };
                    liveSidebarWidth = nil; dragBaseWidth = nil
                }
            )
            .onTapGesture(count: 2) { sidebarWidth = 230 }
        }
    }
    private var detailColumn: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                DashSkin.paper(scheme == .dark).frame(height: UIScale.pt(41)); detail
            }
            .environment(\.compactLayout, geometry.size.width < UIScale.pt(640))
        }.background(DashSkin.paper(scheme == .dark))
    }
    @ViewBuilder private var detail: some View {
        switch destination.id {
        case "home":
            HostHomePage(
                marketplace: marketplace, customize: customize,
                extensions: { selection = "extensions" }, openExtension: openExtension)
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
                openExtensions: { selection = "extensions" })
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
            selection = route.page
        } else {
            defaults.set(id, forKey: "extensionsExpand")
            selection = "extensions"
        }
    }
    private func content(_ id: String, section: String? = nil) -> some View {
        HostExtensionContent(
            marketplace: marketplace, extensionID: id,
            location: destination.id == "settings" ? "settings" : "main",
            section: section ?? destination.id,
            presenter: presenter, openMarketplace: { selection = "extensions" })
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
    private func customize() { settings = "surfaces"; selection = "settings" }
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let code = event.keyCode
            let modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard NSApp.keyWindow?.identifier?.rawValue == "EdithMainWindow",
                    let command = WindowKeyCommand.resolve(
                        characters: characters, keyCode: code, modifiers: modifiers)
                else { return false }
                if let next = WindowZoom.adjusted(zoom, for: command) {
                    zoom = next; UIScale.apply(next); return true
                }
                guard
                    let index = WindowKeyCommand.resolvedIndex(
                        for: command, count: pages.count,
                        current: pages.firstIndex(of: destination) ?? 0)
                else { return false }
                selection = pages[index].id; return true
            }
            return handled ? nil : event
        }
        hintMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let option = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { showHints = option }
            return event
        }
    }
    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) };
        if let hintMonitor { NSEvent.removeMonitor(hintMonitor) }; keyMonitor = nil;
        hintMonitor = nil
    }
}
