import AppKit
import EdithKit
import SwiftUI

private struct AutomaticViewActionsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var automaticViewActionsEnabled: Bool {
        get { self[AutomaticViewActionsEnabledKey.self] }
        set { self[AutomaticViewActionsEnabledKey.self] = newValue }
    }
}

struct MainNavigationSelection: Equatable {
    let mainWindowSection: String
    let settingsTab: String
}

enum MainNavigationFallback {
    static func resolve(
        mainWindowSection: String, settingsTab: String
    ) -> MainNavigationSelection {
        if mainWindowSection == "shortcuts" {
            return MainNavigationSelection(mainWindowSection: "settings", settingsTab: "shortcuts")
        }
        let section = MainDestination(rawValue: mainWindowSection)?.rawValue ?? "home"
        let validSettingsTabs = [
            "general", "permissions", "shortcuts", "terminal", "icloud", "updates",
        ]
        let resolvedSettingsTab =
            validSettingsTabs.contains(settingsTab) ? settingsTab : "general"
        return MainNavigationSelection(
            mainWindowSection: section, settingsTab: resolvedSettingsTab)
    }
}

enum Brand {
    static var icon: NSImage? { AppArtwork.icon }
}

struct TitlebarChrome: View {
    let height: CGFloat
    let width: CGFloat
    @AppStorage(AppStorageKeys.General.mainSidebarOpen, store: SharedDefaults.store) private
        var sidebarOpen = true

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                sidebarOpen.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.edith(.toolbar))
            .help("Toggle sidebar (⌘B)")
            .keyboardShortcut("b", modifiers: .command)

            if sidebarOpen, width >= 130 {
                HStack(alignment: .center, spacing: 6) {
                    if let icon = Brand.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 17, height: 17)
                    }
                    Text("Edith")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(-0.2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
    }
}

private struct SidebarNavRow: View {
    let item: MainDestination
    let selected: Bool
    let theme: Color
    var indented = false
    let shortcutHint: String?
    let action: () -> Void
    var detach: (() -> Void)?
    var disclosureExpanded: Bool? = nil
    var disclosureAction: (() -> Void)?
    var disclosureLabel = "categories"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowHovered = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                if let detach,
                    SectionWindowCommand.shouldDetach(NSEvent.modifierFlags.swiftUIValue)
                {
                    detach()
                } else {
                    action()
                }
            } label: {
                HStack(spacing: UIScale.pt(11)) {
                    AppGlyph(item, size: UIScale.pt(15), weight: .medium)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(width: UIScale.pt(22))
                    Text(item.title)
                        .font(.system(size: UIScale.pt(13.5), weight: .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let shortcutHint {
                        Text(shortcutHint)
                            .font(.system(size: UIScale.pt(11), weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if disclosureExpanded != nil {
                        Color.clear.frame(
                            width: UIScale.pt(SidebarDisclosureGeometry.controlSlotWidth))
                    }
                }
            }
            .buttonStyle(EdithButtonStyle(.row, selected: selected, tint: theme))
            .padding(.leading, indented ? UIScale.pt(18) : 0)
            .accessibilityValue(
                disclosureExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? ""
            )
            .help(
                detach == nil
                    ? item.title : "\(item.title) (⌘-click to open in its own window)"
            )
            .contextMenu {
                if let detach {
                    Button("Open in New Window", action: detach)
                }
            }

            if let disclosureExpanded, let disclosureAction {
                Button(action: disclosureAction) {
                    disclosureIcon(expanded: disclosureExpanded)
                        .frame(
                            width: UIScale.pt(SidebarDisclosureGeometry.controlSlotWidth),
                            height: UIScale.pt(SidebarDisclosureGeometry.controlSlotWidth)
                        )
                        .background(
                            Color.primary.opacity(rowHovered && !selected ? 0.055 : 0),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
                .padding(.trailing, UIScale.pt(2))
                .zIndex(1)
                .accessibilityLabel(
                    disclosureExpanded
                        ? "Collapse \(disclosureLabel)" : "Expand \(disclosureLabel)"
                )
                .help(
                    disclosureExpanded
                        ? "Collapse \(disclosureLabel)" : "Expand \(disclosureLabel)"
                )
            }
        }
        .onHover { rowHovered = $0 }
    }

    private func disclosureIcon(expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: UIScale.pt(10), weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .animation(
                Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: expanded)
    }
}

enum SidebarDisclosureGeometry {
    static let controlSlotWidth: CGFloat = 28

    static func visibleHeight(contentHeight: CGFloat, progress: Double) -> CGFloat {
        contentHeight * min(1, max(0, progress))
    }
}

struct SidebarUtilityVisibility: Equatable {
    let system: Bool
    let presenter: Bool
    let lidAwake: Bool
    let keystrokeHighlight: Bool

    var hasActions: Bool {
        system || presenter || lidAwake || keystrokeHighlight
    }
}

private struct CollapsibleSidebarLayout: Layout {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: size.width,
            height: SidebarDisclosureGeometry.visibleHeight(
                contentHeight: size.height, progress: progress)
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct SidebarSectionRow: View {
    let child: SidebarChild
    let indented: Bool
    let theme: Color
    let selected: Bool
    let action: () -> Void
    let detach: () -> Void

    var body: some View {
        Button {
            if SectionWindowCommand.shouldDetach(NSEvent.modifierFlags.swiftUIValue) {
                detach()
            } else {
                action()
            }
        } label: {
            HStack(spacing: UIScale.pt(9)) {
                Image(systemName: child.symbolName)
                    .frame(width: UIScale.pt(18))
                Text(child.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: UIScale.pt(12.5), weight: .medium))
            .foregroundStyle(selected ? .primary : .secondary)
        }
        .buttonStyle(EdithButtonStyle(.row, selected: selected, tint: theme))
        .padding(.leading, indented ? UIScale.pt(18) : 0)
        .accessibilityHint(child.summary)
        .help("\(child.title) (⌘-click to open in its own window)")
        .contextMenu {
            Button("Open in New Window", action: detach)
        }
    }
}

private struct CollapsibleRow: ViewModifier {
    let expanded: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        CollapsibleSidebarLayout(progress: expanded ? 1 : 0) {
            content
        }
        .clipped()
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
    }
}

extension NSEvent.ModifierFlags {
    var swiftUIValue: EventModifiers {
        var modifiers = EventModifiers()
        if contains(.command) { modifiers.insert(.command) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

private struct NavStack {
    private(set) var entries: [String] = []
    private(set) var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    mutating func record(_ location: String) {
        if index >= 0, entries[index] == location { return }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(location)
        index = entries.count - 1
    }

    mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func goForward() -> String? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}

struct MainWindowView: View {
    let updater: UpdaterModel

    init(updater: UpdaterModel) {
        self.updater = updater
    }

    @MainActor
    init() {
        self.init(updater: UpdaterModel())
    }
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage(AppStorageKeys.General.settingsTab, store: SharedDefaults.store) private
        var settingsTab = "general"
    @AppStorage(AppStorageKeys.General.mainSidebarOpen, store: SharedDefaults.store) private
        var sidebarOpen = true
    @AppStorage(AppStorageKeys.General.mainSidebarWidth, store: SharedDefaults.store) private
        var sidebarWidth = 230.0
    @AppStorage(
        AppStorageKeys.General.settingsCategoriesExpanded, store: SharedDefaults.store
    ) private var settingsCategoriesExpanded = true
    @AppStorage(
        AppStorageKeys.AppMaintenance.categoriesExpanded, store: SharedDefaults.store
    ) private var appMaintenanceSectionsExpanded = true
    @AppStorage(AppStorageKeys.AppMaintenance.section, store: SharedDefaults.store) private
        var appMaintenanceSection = AppMaintenanceSection.updates.rawValue
    @AppStorage(AppStorageKeys.Tabs.attentionEnabled, store: SharedDefaults.store) private
        var attentionEnabled = false
    @AppStorage(AppStorageKeys.Tabs.systemEnabled, store: SharedDefaults.store) private
        var systemEnabled = false
    @AppStorage(AppStorageKeys.AppMaintenance.enabled, store: SharedDefaults.store) private
        var appMaintenanceEnabled = false
    @AppStorage(AppStorageKeys.Tabs.musicEnabled, store: SharedDefaults.store) private
        var musicEnabled = false
    @AppStorage(AppStorageKeys.Tabs.usageEnabled, store: SharedDefaults.store) private
        var usageEnabled = false
    @AppStorage(AppStorageKeys.Tabs.herdrEnabled, store: SharedDefaults.store) private
        var herdrEnabled = false
    @AppStorage(AppStorageKeys.Tabs.quinjetEnabled, store: SharedDefaults.store) private
        var quinjetEnabled = false
    @AppStorage(AppStorageKeys.Tabs.seoAuditEnabled, store: SharedDefaults.store) private
        var seoAuditEnabled = false
    @AppStorage(AppStorageKeys.Tabs.calendarEnabled, store: SharedDefaults.store) private
        var calendarEnabled =
        false
    @AppStorage(AppStorageKeys.Homebrew.enabled, store: SharedDefaults.store) private
        var homebrewEnabled = false
    @AppStorage(AppStorageKeys.Cleaner.enabled, store: SharedDefaults.store) private
        var cleanerEnabled = false
    @AppStorage(AppStorageKeys.Suites.agents, store: SharedDefaults.store) private
        var agentsSuite = false
    @AppStorage(AppStorageKeys.Suites.maintenance, store: SharedDefaults.store) private
        var maintenanceSuite = false
    @AppStorage(AppStorageKeys.Suites.system, store: SharedDefaults.store) private
        var systemSuite = false
    @AppStorage(AppStorageKeys.Suites.desk, store: SharedDefaults.store) private
        var deskSuite = false
    @AppStorage(AppStorageKeys.Suites.media, store: SharedDefaults.store) private
        var mediaSuite = false
    @AppStorage(AppStorageKeys.Music.barAutoHide, store: SharedDefaults.store) private
        var musicBarAutoHide = false
    @AppStorage(AppStorageKeys.Suites.data, store: SharedDefaults.store) private
        var dataSuite = false
    @AppStorage(AppStorageKeys.Tabs.databaseEnabled, store: SharedDefaults.store) private
        var databaseEnabled =
        false
    @AppStorage(AppStorageKeys.Tabs.companionEnabled, store: SharedDefaults.store) private
        var companionEnabled =
        false
    @AppStorage(AppStorageKeys.General.preventSleep, store: SharedDefaults.store) private
        var preventSleep = false
    @AppStorage(LidAwakeState.enabledKey, store: SharedDefaults.store) private
        var lidAwakeEnabled = false
    @AppStorage(AppStorageKeys.KeystrokeHighlight.enabled, store: SharedDefaults.store) private
        var keystrokeHighlightEnabled = false
    @AppStorage(AppStorageKeys.KeystrokeHighlight.active, store: SharedDefaults.store) private
        var keystrokeHighlightActive = false
    @AppStorage(AppStorageKeys.Presenter.mode, store: SharedDefaults.store) private
        var presenterMode = false
    @AppStorage(AppStorageKeys.Presenter.enabled, store: SharedDefaults.store) private
        var presenterEnabled =
        false
    @AppStorage(AppStorageKeys.Presenter.blurMusic, store: SharedDefaults.store) private
        var presenterBlurMusic =
        true
    @AppStorage(AppStorageKeys.Presenter.blurMoney, store: SharedDefaults.store) private
        var presenterBlurMoney =
        true
    @AppStorage(AppStorageKeys.Presenter.blurUsage, store: SharedDefaults.store) private
        var presenterBlurUsage =
        false
    @AppStorage(AppStorageKeys.Presenter.blurCalendar, store: SharedDefaults.store)
    private var presenterBlurCalendar = true
    @AppStorage(AppStorageKeys.Presenter.blurAgents, store: SharedDefaults.store)
    private var presenterBlurAgents = true
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.General.creditHidden, store: SharedDefaults.store) private
        var creditHidden = false
    @AppStorage(WindowZoom.defaultsKey, store: SharedDefaults.store) private var zoom = 1.0
    @AppStorage(AppStorageKeys.General.editMainWindowFullScreen) private var windowFullScreen =
        false
    @State private var dragBaseWidth: Double?
    @State private var liveSidebarWidth: Double?
    @State private var musicKeyMonitor: Any?
    @State private var windowKeyMonitor: Any?
    @State private var commandHintMonitor: Any?
    @State private var commandHintWork: DispatchWorkItem?
    @State private var showShortcutHints = false
    @State private var nav = NavStack()
    @State private var musicFolderPath = ""
    @State private var restoringHistory = false
    @State private var permissionsNeedAttention = PermissionsStatus.current
    @State private var permissionsProbe: Task<Void, Never>?
    @State private var presenterQuickActionsPresented = false
    @State private var hoveredPresenterQuickAction: String?
    @State private var keyboardCleanTrigger = 0
    @State private var lidAwakeActive = SharedDefaults.store.bool(
        forKey: LidAwakeState.activeKey)
    @State private var confirmingLidAwake = false
    @StateObject private var lidAwakeOperations = LidAwakeOperationModel()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    private var theme: Color { themeColor(themeName) }

    private static let minSidebarWidth = 180.0
    private static let maxSidebarWidth = 320.0
    private static let defaultSidebarWidth = 230.0
    private static let trafficLightsInset = 94.0
    private static let chromeHeight = 31.0
    private static let fullScreenControlsInset = 12.0

    private var clampedSidebarWidth: Double {
        min(Self.maxSidebarWidth, max(Self.minSidebarWidth, liveSidebarWidth ?? sidebarWidth))
    }

    private var displaySidebarWidth: Double { UIScale.pt(clampedSidebarWidth) }

    private var destination: MainDestination {
        let requested = MainDestination.resolve(navigationSelection.mainWindowSection)
        _ = extensionSelectionToken
        return requested.page.isVisible(in: SharedDefaults.store) ? requested : .home
    }

    private var navigationSelection: MainNavigationSelection {
        MainNavigationFallback.resolve(
            mainWindowSection: mainWindowSection, settingsTab: settingsTab)
    }

    private var currentLocation: String {
        if destination == .settings {
            return "settings/\(navigationSelection.settingsTab)"
        }
        if destination == .music, !musicFolderPath.isEmpty {
            return "music/\(musicFolderPath)"
        }
        return navigationSelection.mainWindowSection
    }

    private func navigate(to location: String) {
        restoringHistory = true
        let music = MainDestination.music.rawValue
        if location.hasPrefix("settings/") {
            settingsTab = String(location.dropFirst("settings/".count))
            mainWindowSection = MainDestination.settings.rawValue
        } else if location == music || location.hasPrefix(music + "/") {
            MusicRemote.shared.navigate(
                to: location.hasPrefix(music + "/")
                    ? String(location.dropFirst(music.count + 1)) : "")
            mainWindowSection = music
        } else {
            mainWindowSection = location
        }
    }

    private func goBack() {
        if let location = nav.goBack() { navigate(to: location) }
    }

    private func goForward() {
        if let location = nav.goForward() { navigate(to: location) }
    }

    var body: some View {
        GeometryReader { geo in
            let bandHeight = Self.chromeHeight + UIScale.pt(10)
            VStack(spacing: 0) {
                mainArea(bandHeight)
                if musicFooterVisible {
                    MusicFooter()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            .overlay { MusicDetailOverlay() }
            .overlay(alignment: .topLeading) { chromeOverlay() }
            .animation(
                Motion.animation(Motion.glide, reduceMotion: reduceMotion),
                value: visibleHomeItems
            )
            .animation(
                Motion.animation(Motion.glide, reduceMotion: reduceMotion),
                value: footerVisible)
        }
        .background(historyShortcuts)
        .onExitCommand { InputFocus.resignEditing() }
        .onChange(of: MusicRemote.shared.folderPath, initial: true) { _, newValue in
            musicFolderPath = newValue
        }
        .onChange(of: destination) { _, opened in
            PageTrace.begin(opened)
        }
        .onChange(of: currentLocation) { _, location in
            if restoringHistory {
                restoringHistory = false
            } else {
                nav.record(location)
            }
        }
        .onAppear {
            guard automaticActionsEnabled else { return }
            applyNavigationFallback()
            installWindowKeys()
            installCommandHintMonitor()
            syncMusicResources()
            PresenterState.shared.syncEnabled(presenterEnabled)
            refreshPermissionsPill()
            if nav.entries.isEmpty { nav.record(currentLocation) }
        }
        .onChange(of: musicEnabled) { _, _ in
            if automaticActionsEnabled { syncMusicResources() }
        }
        .onChange(of: presenterEnabled) { _, on in
            if automaticActionsEnabled { PresenterState.shared.syncEnabled(on) }
        }
        .onDisappear {
            guard automaticActionsEnabled else { return }
            permissionsProbe?.cancel()
            removeWindowKeys()
            removeCommandHintMonitor()
            removeMusicKeys()
            MusicRemote.shared.stop()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            if automaticActionsEnabled { refreshPermissionsPill() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification)
        ) { _ in
            dismissCommandHints()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            if automaticActionsEnabled {
                permissionsNeedAttention = PermissionsStatus.current
            }
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.lidAwakeChanged)
        ) { _ in
            lidAwakeActive = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)
            lidAwakeOperations.refreshStatus()
        }
        .alert("Keep running with the lid closed?", isPresented: $confirmingLidAwake) {
            Button("Turn On") {
                lidAwakeOperations.perform(.on(LidAwakeState.session()))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                LidAwakeOperationExecution.preview(for: .on(LidAwakeState.session()))?.warning
                    ?? "")
        }
        .alert(
            "Lid Awake could not change state",
            isPresented: Binding(
                get: {
                    lidAwakeOperations.errorMessage != nil
                        || lidAwakeOperations.lastSnapshot?.lastError != nil
                },
                set: { if !$0 { lidAwakeOperations.clearError() } })
        ) {
            Button("OK") { lidAwakeOperations.clearError() }
        } message: {
            Text(
                lidAwakeOperations.errorMessage
                    ?? lidAwakeOperations.lastSnapshot?.lastError ?? "")
        }
    }

    private func applyNavigationFallback() {
        let resolved = navigationSelection
        mainWindowSection = resolved.mainWindowSection
        settingsTab = resolved.settingsTab
    }

    private var historyShortcuts: some View {
        ZStack {
            Button("", action: goBack)
                .keyboardShortcut("[", modifiers: .command)
            Button("", action: goForward)
                .keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func installMusicKeys() {
        guard musicKeyMonitor == nil else { return }
        musicKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let mods = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                let remote = MusicRemote.shared
                return MusicKeyCommand.handle(
                    keyCode: code, modifiers: mods, active: remote.current != nil,
                    .init(
                        playPause: { remote.playPause() },
                        seekBy: { remote.nudgeSeek($0) },
                        volumeBy: { remote.nudgeVolume($0) }))
            }
            return handled ? nil : event
        }
    }

    private func syncMusicResources() {
        if musicEnabled {
            MusicRemote.shared.start()
            installMusicKeys()
        } else {
            removeMusicKeys()
            MusicRemote.shared.stop()
        }
    }

    private func removeMusicKeys() {
        if let monitor = musicKeyMonitor {
            NSEvent.removeMonitor(monitor)
            musicKeyMonitor = nil
        }
    }

    private var musicFooterVisible: Bool {
        guard musicEnabled, mediaSuite else { return false }
        return !musicBarAutoHide || MusicRemote.shared.current != nil
    }

    private var detailShadow: Color {
        scheme == .dark ? .black.opacity(0.55) : .black.opacity(0.16)
    }

    private var detailBackground: Color {
        DashSkin.paper(scheme == .dark)
    }

    private var detailCorner: CGFloat { sidebarOpen ? 12 : 0 }

    private func mainArea(_ bandHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            sidebar(bandHeight)
                .frame(width: displaySidebarWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            detailColumn(bandHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: detailCorner, bottomLeadingRadius: detailCorner,
                        style: .continuous)
                )
                .padding(.leading, sidebarOpen ? displaySidebarWidth : 0)
                .shadow(color: detailShadow, radius: UIScale.pt(18), x: -6, y: 0)

            sidebarEdge
                .frame(maxHeight: .infinity)
                .offset(x: sidebarOpen ? displaySidebarWidth : 0)
                .opacity(sidebarOpen ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: sidebarOpen)
    }

    private func refreshPermissionsPill() {
        permissionsNeedAttention = PermissionsStatus.current
        permissionsProbe?.cancel()
        permissionsProbe = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            CalendarPermission.mirror()
            IPC.post(IPC.Name.requestPermissionsRefresh)
        }
    }

    private func chromeOverlay() -> some View {
        let inset = windowFullScreen ? Self.fullScreenControlsInset : Self.trafficLightsInset
        return VStack(spacing: 0) {
            TitlebarChrome(
                height: Self.chromeHeight,
                width: sidebarOpen ? max(displaySidebarWidth - inset, 60) : UIScale.pt(200))
            Spacer(minLength: 0)
        }
        .padding(.leading, inset)
        .ignoresSafeArea(edges: .top)
    }

    private func band(_ color: Color, height: CGFloat) -> some View {
        color
            .frame(height: height)
            .allowsHitTesting(false)
    }

    private func detailColumn(_ bandHeight: CGFloat) -> some View {
        GeometryReader { geo in
            VStack(spacing: UIScale.pt(0)) {
                band(detailBackground, height: bandHeight)
                detail
                    .tint(theme)
                    .onAppear { PageTrace.end(destination) }
            }
            .environment(\.compactLayout, geo.size.width < UIScale.pt(640))
        }
        .background(detailBackground)
    }

    private var footerVisible: Bool {
        sidebarUtilityVisibility.hasActions || permissionsNeedAttention
            || updater.updateReady != nil
    }

    private var sidebarUtilityVisibility: SidebarUtilityVisibility {
        SidebarUtilityVisibility(
            system: systemEnabled,
            presenter: presenterEnabled,
            lidAwake: lidAwakeEnabled,
            keystrokeHighlight: keystrokeHighlightEnabled)
    }

    private var sidebarUtilityTransition: AnyTransition {
        Motion.transition(
            .move(edge: .bottom).combined(with: .opacity),
            reduceMotion: reduceMotion,
            preferCrossFade: false)
    }

    private func sidebar(_ bandHeight: CGFloat) -> some View {
        ZStack {
            SidebarMaterial()
            VStack(spacing: UIScale.pt(0)) {
                band(.clear, height: bandHeight)
                VStack(spacing: UIScale.pt(0)) {
                    sidebarList
                    if footerVisible {
                        VStack(spacing: 0) {
                            Divider()
                            sidebarFooter
                        }
                        .transition(sidebarUtilityTransition)
                    }
                    credit
                        .padding(.vertical, UIScale.pt(8))
                }
            }
        }
    }

    private var sidebarList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                ForEach(sidebarRows) { row in
                    sidebarRow(row)
                }
            }
            .padding(.horizontal, UIScale.pt(8))
            .padding(.top, UIScale.pt(8))
        }
        .frame(maxHeight: .infinity)
        .animation(
            Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: destination
        )
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: showShortcutHints
        )
        .animation(
            Motion.animation(Motion.snap, reduceMotion: reduceMotion),
            value: settingsCategoriesExpanded
        )
        .animation(
            Motion.animation(Motion.snap, reduceMotion: reduceMotion),
            value: appMaintenanceSectionsExpanded
        )
    }

    @ViewBuilder
    private func sidebarRow(_ row: SidebarRow) -> some View {
        switch row {
        case let .page(page):
            if page.band == .app, page.id == MainDestination.appItems.first?.rawValue {
                Text("App")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, UIScale.pt(8))
                    .padding(.top, UIScale.pt(14))
                    .padding(.bottom, UIScale.pt(4))
            }
            pageRow(page)
        case let .section(parent, child):
            SidebarSectionRow(
                child: child, indented: true, theme: theme,
                selected: destination.rawValue == parent
                    && selectedChild(of: parent) == child.id,
                action: { selectChild(child, of: parent) },
                detach: { detachChild(child, of: parent) }
            )
            .modifier(
                CollapsibleRow(
                    expanded: isExpanded(parent),
                    reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private func pageRow(_ page: SidebarPage) -> some View {
        let item = MainDestination.resolve(page.id)
        let expandable = !page.children.isEmpty
        SidebarNavRow(
            item: item, selected: destination == item, theme: theme,
            indented: page.parentID != nil,
            shortcutHint: shortcutHint(for: item),
            action: {
                if expandable, destination == item {
                    toggleExpansion(page.id)
                } else {
                    select(item)
                }
            },
            detach: page.detachable ? { detach(item) } : nil,
            disclosureExpanded: expandable ? isExpanded(page.id) : nil,
            disclosureAction: expandable ? { toggleExpansion(page.id) } : nil,
            disclosureLabel: "\(page.title) sections")
    }

    private var sidebarRows: [SidebarRow] {
        _ = extensionSelectionToken
        return NavigationCatalog.rows()
    }

    private var extensionSelectionToken: [Bool] {
        [
            usageEnabled, herdrEnabled, quinjetEnabled, companionEnabled, appMaintenanceEnabled,
            homebrewEnabled, cleanerEnabled, systemEnabled, musicEnabled, calendarEnabled,
            databaseEnabled, attentionEnabled, seoAuditEnabled, agentsSuite, maintenanceSuite,
            systemSuite, mediaSuite, dataSuite,
        ]
    }

    private func isExpanded(_ pageID: String) -> Bool {
        switch pageID {
        case MainDestination.settings.rawValue: settingsCategoriesExpanded
        case MainDestination.appMaintenance.rawValue: appMaintenanceSectionsExpanded
        default: true
        }
    }

    private func toggleExpansion(_ pageID: String) {
        switch pageID {
        case MainDestination.settings.rawValue: settingsCategoriesExpanded.toggle()
        case MainDestination.appMaintenance.rawValue: appMaintenanceSectionsExpanded.toggle()
        default: break
        }
    }

    private func selectedChild(of pageID: String) -> String? {
        switch pageID {
        case MainDestination.settings.rawValue: navigationSelection.settingsTab
        case MainDestination.appMaintenance.rawValue: appMaintenanceSection
        default: nil
        }
    }

    private func selectChild(_ child: SidebarChild, of pageID: String) {
        switch pageID {
        case MainDestination.settings.rawValue: settingsTab = child.id
        case MainDestination.appMaintenance.rawValue: appMaintenanceSection = child.id
        default: return
        }
        mainWindowSection = pageID
    }

    private func detachChild(_ child: SidebarChild, of pageID: String) {
        switch pageID {
        case MainDestination.settings.rawValue: settingsTab = child.id
        case MainDestination.appMaintenance.rawValue: appMaintenanceSection = child.id
        default: return
        }
        SectionWindow.open(MainDestination.resolve(pageID))
    }

    private func select(_ item: MainDestination) {
        if SectionWindow.focusExisting(item) { return }
        mainWindowSection = item.rawValue
    }

    private func detach(_ item: MainDestination) {
        SectionWindow.open(item)
    }

    private var visibleHomeItems: [MainDestination] {
        _ = extensionSelectionToken
        return NavigationCatalog.destinations().filter { $0.page.band != .app }
    }

    private var navigableItems: [MainDestination] {
        visibleHomeItems + MainDestination.appItems
    }

    private func shortcutHint(for item: MainDestination) -> String? {
        guard showShortcutHints else { return nil }
        let items = navigableItems
        guard let index = items.firstIndex(of: item) else { return nil }
        if index < WindowKeyCommand.directSelectLimit { return "⌘\(index + 1)" }
        return index == items.count - 1 ? "⌘9" : nil
    }

    private func installWindowKeys() {
        guard windowKeyMonitor == nil else { return }
        windowKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let code = event.keyCode
            let mods = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard NSApp.keyWindow?.identifier?.rawValue == MainWindowIdentifier.value else {
                    return false
                }
                guard !WindowTabs.isTabbed(NSApp.keyWindow) else { return false }
                guard
                    let command = WindowKeyCommand.resolve(
                        characters: characters, keyCode: code, modifiers: mods)
                else { return false }
                if let next = WindowZoom.adjusted(zoom, for: command) {
                    zoom = next
                    return true
                }
                let items = navigableItems
                guard
                    let index = WindowKeyCommand.resolvedIndex(
                        for: command, count: items.count,
                        current: items.firstIndex(of: destination) ?? 0)
                else { return false }
                mainWindowSection = items[index].rawValue
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeWindowKeys() {
        if let monitor = windowKeyMonitor {
            NSEvent.removeMonitor(monitor)
            windowKeyMonitor = nil
        }
    }

    private func installCommandHintMonitor() {
        guard commandHintMonitor == nil else { return }
        commandHintMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let commandDown = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated {
                if commandDown {
                    guard commandHintWork == nil, !showShortcutHints else { return }
                    let work = DispatchWorkItem {
                        showShortcutHints = true
                        commandHintWork = nil
                    }
                    commandHintWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                } else {
                    dismissCommandHints()
                }
            }
            return event
        }
    }

    private func removeCommandHintMonitor() {
        dismissCommandHints()
        if let monitor = commandHintMonitor {
            NSEvent.removeMonitor(monitor)
            commandHintMonitor = nil
        }
    }

    private func dismissCommandHints() {
        commandHintWork?.cancel()
        commandHintWork = nil
        showShortcutHints = false
    }

    private var sidebarFooter: some View {
        VStack(spacing: UIScale.pt(8)) {
            if let version = updater.updateReady {
                updateReadyPill(version)
            }
            if sidebarUtilityVisibility.hasActions {
                quickActions
            }
            if permissionsNeedAttention {
                permissionsPill
            }
        }
        .padding(UIScale.pt(10))
    }

    private func updateReadyPill(_ version: String) -> some View {
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update ready")
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                Text("v\(version)")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .opacity(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashSkin.sage)
            .padding(.horizontal, UIScale.pt(9))
            .frame(height: UIScale.pt(28))
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        }
        .buttonStyle(.edith(.borderless))
        .help("Show update options")
    }

    @ViewBuilder
    private var quickActions: some View {
        let tiles = [
            quickActionTile(
                icon: "keyboard", title: "Clean keys", active: false,
                trigger: keyboardCleanTrigger,
                help: "Lock the keyboard so you can wipe it"
            ) {
                keyboardCleanTrigger += 1
                AppRuntimeCenter().request(.cleanKeys)
            },
            quickActionTile(
                icon: preventSleep ? "moon.zzz.fill" : "moon.zzz", title: "Keep awake",
                active: preventSleep, trigger: preventSleep ? 1 : 0,
                help: "Keep this Mac from sleeping until turned off"
            ) {
                $preventSleep.configured(AppStorageKeys.General.preventSleep).wrappedValue.toggle()
            },
        ]
        VStack(spacing: UIScale.pt(8)) {
            if systemEnabled {
                VStack(spacing: UIScale.pt(8)) {
                    if clampedSidebarWidth < 220 {
                        tiles[0]; tiles[1]
                    } else {
                        HStack(spacing: UIScale.pt(8)) {
                            tiles[0]; tiles[1]
                        }
                    }
                }
                .transition(sidebarUtilityTransition)
            }
            if lidAwakeEnabled || keystrokeHighlightEnabled {
                VStack(spacing: UIScale.pt(8)) {
                    if lidAwakeEnabled && keystrokeHighlightEnabled {
                        if clampedSidebarWidth < 220 {
                            lidAwakeQuickActionTile
                            keystrokeHighlightQuickActionTile
                        } else {
                            HStack(spacing: UIScale.pt(8)) {
                                lidAwakeQuickActionTile
                                keystrokeHighlightQuickActionTile
                            }
                        }
                    } else if lidAwakeEnabled {
                        lidAwakeQuickActionTile
                    } else {
                        keystrokeHighlightQuickActionTile
                    }
                }
                .transition(sidebarUtilityTransition)
            }
            if presenterEnabled {
                presenterQuickActionTile
                    .transition(sidebarUtilityTransition)
            }
        }
        .animation(
            Motion.animation(Motion.glide, reduceMotion: reduceMotion),
            value: sidebarUtilityVisibility)
    }

    private var lidAwakeQuickActionTile: some View {
        quickActionTile(
            icon: "laptopcomputer", title: "Lid awake", active: lidAwakeActive,
            trigger: lidAwakeActive ? 1 : 0,
            help: "Keep this Mac running with the lid closed"
        ) {
            if lidAwakeActive {
                lidAwakeOperations.perform(.off)
            } else {
                confirmingLidAwake = true
            }
        }
    }

    private var keystrokeHighlightQuickActionTile: some View {
        quickActionTile(
            icon: "keyboard.badge.ellipsis", title: "Keystrokes",
            active: keystrokeHighlightActive,
            trigger: keystrokeHighlightActive ? 1 : 0,
            help: "Show keyboard input on screen"
        ) {
            $keystrokeHighlightActive
                .configured(AppStorageKeys.KeystrokeHighlight.active).wrappedValue.toggle()
        }
    }

    private var presenterQuickActionTile: some View {
        HStack(spacing: UIScale.pt(0)) {
            Button {
                setPresenterMode(!presenterMode)
            } label: {
                VStack(spacing: UIScale.pt(4)) {
                    Image(systemName: "theatermasks.fill")
                        .font(.system(size: UIScale.pt(14)))
                        .symbolEffect(.bounce, value: presenterMode)
                    Text("Presenter mode")
                        .font(.system(size: UIScale.pt(10), weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UIScale.pt(8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("Blur sensitive numbers and track names everywhere in Edith")

            Rectangle()
                .fill(presenterMode ? Color.white.opacity(0.24) : Color.primary.opacity(0.08))
                .frame(width: UIScale.pt(1), height: UIScale.pt(28))

            Button {
                presenterQuickActionsPresented.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .symbolEffect(.bounce, value: presenterQuickActionsPresented)
                    .frame(width: UIScale.pt(30), height: UIScale.pt(46))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .help("Choose what Presenter mode blurs")
            .popover(isPresented: $presenterQuickActionsPresented, arrowEdge: .leading) {
                presenterQuickActionsPopover
            }
        }
        .foregroundStyle(presenterMode ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .background(
            presenterMode ? AnyShapeStyle(theme) : AnyShapeStyle(.thinMaterial),
            in: RoundedRectangle(cornerRadius: UIScale.pt(9))
        )
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
    }

    private var presenterQuickActionsPopover: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            Text("Presenter mode")
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .padding(.bottom, UIScale.pt(10))
            presenterQuickActionToggle(
                "Presenter mode",
                isOn: Binding(get: { presenterMode }, set: { setPresenterMode($0) })
            )
            Divider()
            presenterQuickActionToggle(
                "Blur music",
                isOn: $presenterBlurMusic.configured(AppStorageKeys.Presenter.blurMusic))
            Divider()
            presenterQuickActionToggle(
                "Blur cost figures",
                isOn: $presenterBlurMoney.configured(AppStorageKeys.Presenter.blurMoney))
            Divider()
            presenterQuickActionToggle(
                "Blur usage figures",
                isOn: $presenterBlurUsage.configured(AppStorageKeys.Presenter.blurUsage))
            Divider()
            presenterQuickActionToggle(
                "Blur calendar events",
                isOn: $presenterBlurCalendar.configured(AppStorageKeys.Presenter.blurCalendar))
            Divider()
            presenterQuickActionToggle(
                "Blur agents",
                isOn: $presenterBlurAgents.configured(AppStorageKeys.Presenter.blurAgents))
        }
        .padding(UIScale.pt(14))
        .frame(width: UIScale.pt(250))
    }

    private func setPresenterMode(_ on: Bool) {
        _ = PresenterRuntimeOperationExecution.perform(on ? .start : .stop)
    }

    private func presenterQuickActionToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                Text(title)
                    .font(.system(size: UIScale.pt(12.5)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .background(
                hoveredPresenterQuickAction == title ? Color.primary.opacity(0.06) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .onHover { hovering in
            if hovering {
                hoveredPresenterQuickAction = title
            } else if hoveredPresenterQuickAction == title {
                hoveredPresenterQuickAction = nil
            }
        }
    }

    private func quickActionTile(
        icon: String, title: String, active: Bool, trigger: Int, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: UIScale.pt(4)) {
                Image(systemName: icon)
                    .font(.system(size: UIScale.pt(14)))
                    .symbolEffect(.bounce, value: trigger)
                Text(title)
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UIScale.pt(8))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(
                active ? AnyShapeStyle(theme) : AnyShapeStyle(.thinMaterial),
                in: RoundedRectangle(cornerRadius: UIScale.pt(9))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .help(help)
    }

    private var sidebarEdge: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: UIScale.pt(1))
            .overlay {
                Color.clear
                    .frame(width: UIScale.pt(9))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragBaseWidth ?? displaySidebarWidth
                                dragBaseWidth = base
                                liveSidebarWidth = min(
                                    Self.maxSidebarWidth,
                                    max(
                                        Self.minSidebarWidth,
                                        (base + value.translation.width) / UIScale.current))
                            }
                            .onEnded { _ in
                                if let width = liveSidebarWidth { sidebarWidth = width }
                                liveSidebarWidth = nil
                                dragBaseWidth = nil
                            }
                    )
                    .onTapGesture(count: 2) { sidebarWidth = Self.defaultSidebarWidth }
            }
    }

    @ViewBuilder
    private var credit: some View {
        if !creditHidden {
            HStack(spacing: UIScale.pt(3)) {
                Spacer(minLength: 0)
                Text("Made with ♥ by")
                    .foregroundStyle(.tertiary)
                Button("Pulkit") {
                    _ = try? AppInspectionCenter().openLink("creator", contributors: [])
                }
                .buttonStyle(.edith(.borderless))
                .fontWeight(.semibold)
                .foregroundStyle(theme)
                .help("pulkit.page")
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { creditHidden = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: UIScale.pt(8), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                }
                .buttonStyle(.edith(.toolbar))
                .help("Hide this")
            }
            .font(.system(size: UIScale.pt(10)))
            .padding(.horizontal, UIScale.pt(8))
            .frame(maxWidth: .infinity)
        }
    }

    private var permissionsPill: some View {
        Button {
            settingsTab = SettingsPane.Tab.permissions.rawValue
            mainWindowSection = MainDestination.settings.rawValue
        } label: {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Permissions need attention")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, UIScale.pt(8))
            .frame(height: UIScale.pt(26))
            .background(
                Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
        }
        .buttonStyle(.edith(.borderless))
    }

    private var detail: some View {
        PageContent(destination, updater: updater)
    }
}
