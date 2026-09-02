import AppKit
import EdithKit
import SwiftUI
import Testing
@testable import Edith
@testable import EdithHelper

@MainActor
private func renderedBitmap(
    _ view: some View, width: CGFloat = 900, height: CGFloat = 700
) -> NSBitmapImageRep? {
    let host = NSHostingView(
        rootView:
            view
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.companionRequestsEnabled, false)
            .environment(\.machineConnectionsEnabled, false)
            .environment(\.terminalLaunchEnabled, false))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = TestWindowHost.window(contentRect: host.frame)
    defer { window.orderOut(nil) }
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

@MainActor
private func renders(_ view: some View, width: CGFloat = 900, height: CGFloat = 700) -> Bool {
    guard let rep = renderedBitmap(view, width: width, height: height) else { return false }
    return rep.pixelsWide > 0 && rep.pixelsHigh > 0
}

@MainActor
private func descendantViews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { descendantViews(of: $0) }
}

@MainActor private func smokeUpdater() -> UpdaterModel {
    UpdaterModel(
        logURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edith-smoke-\(UUID().uuidString).json"))
}

@MainActor @Suite(.serialized) struct UISmokeTests {
    init() {
        _ = TestWindowHost.application
    }

    @Test func loadingSkeletonsRender() {
        #expect(renders(MachineOverviewSkeleton(dark: true)))
        #expect(renders(FleetHomeSkeleton(dark: true)))
        #expect(renders(ListRowsSkeleton(rows: 4, dark: true)))
        #expect(renders(FinderSkeleton(mode: .list, dark: true)))
        #expect(renders(FinderSkeleton(mode: .icon, dark: true)))
        #expect(renders(MetricCardSkeleton(dark: false), width: 300, height: 160))
    }

    @Test func everyAppMaintenanceSkeletonRenders() {
        #expect(renders(AppMaintenanceSectionSkeleton(section: .updates)))
        #expect(renders(HomebrewPageSkeleton()))
        #expect(renders(AppMaintenanceSectionSkeleton(section: .removal)))
        #expect(renders(AppMaintenanceSectionSkeleton(section: .history)))
    }

    @Test func homePageRenders() {
        #expect(renders(HomePage()))
    }

    @Test func appMaintenanceRendersInstalledPackagesAndUpdates() {
        let model = HomebrewPageModel()
        model.status = HomebrewStatus(
            available: true, executable: "/opt/homebrew/bin/brew", version: "Homebrew 5.0.0")
        model.loaded = true
        model.packages = [
            HomebrewPackage(
                kind: .formula, name: "ripgrep", displayName: "ripgrep",
                description: "Search text quickly", installedVersions: ["14.1.0"],
                currentVersion: "14.1.1", outdated: true),
            HomebrewPackage(
                kind: .formula, name: "jq", displayName: "jq",
                description: "Process JSON", installedVersions: ["1.7.1"],
                currentVersion: "1.7.1"),
        ]

        #expect(renders(HomebrewMaintenanceView(model: model)))
    }

    @Test func mainWindowRendersEveryDestination() {
        let saved = SharedDefaults.store.string(forKey: "mainWindowSection")
        let savedSettingsTab = SharedDefaults.store.string(forKey: "settingsTab")
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: "mainWindowSection")
            } else {
                SharedDefaults.store.removeObject(forKey: "mainWindowSection")
            }
            if let savedSettingsTab {
                SharedDefaults.store.set(savedSettingsTab, forKey: "settingsTab")
            } else {
                SharedDefaults.store.removeObject(forKey: "settingsTab")
            }
        }
        for destination in MainDestination.allCases {
            SharedDefaults.store.set(destination.rawValue, forKey: "mainWindowSection")
            #expect(
                renders(MainWindowView(updater: smokeUpdater())),
                "\(destination.rawValue) failed to render")
        }
        SharedDefaults.store.set("permissions", forKey: "mainWindowSection")
        #expect(
            renders(MainWindowView(updater: smokeUpdater())),
            "legacy permissions destination failed to render")
        SharedDefaults.store.set("general", forKey: "settingsTab")
        SharedDefaults.store.set("shortcuts", forKey: "mainWindowSection")
        #expect(
            renders(MainWindowView(updater: smokeUpdater())),
            "legacy shortcuts destination failed to render")
    }

    @Test func extensionsPaneRenders() {
        #expect(renders(ExtensionsPane()))
    }

    @Test func extensionSettingsHeaderRendersTrailingSwitch() throws {
        let host = NSHostingView(
            rootView: ExtensionSettingsHeader(title: "Lid Awake", enabled: .constant(false)))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 64)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let switches = descendantViews(of: host).compactMap { $0 as? NSSwitch }
        #expect(switches.count == 1)
        let toggle = try #require(switches.first)
        let frame = host.convert(toggle.bounds, from: toggle)

        #expect(!toggle.isHidden)
        #expect(toggle.isEnabled)
        #expect(frame.midX > host.bounds.midX)
    }

    @Test func extensionSettingsHeaderDisablesOnlyItsSwitchWhileApplying() throws {
        let host = NSHostingView(
            rootView: ExtensionSettingsHeader(
                title: "Lid Awake", enabled: .constant(true), disabled: true))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 64)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let switches = descendantViews(of: host).compactMap { $0 as? NSSwitch }
        #expect(switches.count == 1)
        #expect(try !#require(switches.first).isEnabled)
    }

    @Test func closedSidebarIsCoveredByDetailBackground() throws {
        let sectionKey = AppStorageKeys.General.mainWindowSection
        let sidebarKey = AppStorageKeys.General.mainSidebarOpen
        let savedSection = SharedDefaults.store.object(forKey: sectionKey)
        let savedSidebar = SharedDefaults.store.object(forKey: sidebarKey)
        defer {
            if let savedSection {
                SharedDefaults.store.set(savedSection, forKey: sectionKey)
            } else {
                SharedDefaults.store.removeObject(forKey: sectionKey)
            }
            if let savedSidebar {
                SharedDefaults.store.set(savedSidebar, forKey: sidebarKey)
            } else {
                SharedDefaults.store.removeObject(forKey: sidebarKey)
            }
        }
        SharedDefaults.store.set(MainDestination.extensions.rawValue, forKey: sectionKey)
        SharedDefaults.store.set(false, forKey: sidebarKey)

        let bitmap = try #require(renderedBitmap(MainWindowView(updater: smokeUpdater())))
        let scaleX = CGFloat(bitmap.pixelsWide) / 900
        let scaleY = CGFloat(bitmap.pixelsHigh) / 700
        let leftColor = try #require(
            bitmap.colorAt(x: Int(10 * scaleX), y: Int(350 * scaleY))?.usingColorSpace(.deviceRGB)
        )
        let rightColor = try #require(
            bitmap.colorAt(x: Int(890 * scaleX), y: Int(350 * scaleY))?.usingColorSpace(.deviceRGB)
        )
        #expect(abs(leftColor.redComponent - rightColor.redComponent) < 0.01)
        #expect(abs(leftColor.greenComponent - rightColor.greenComponent) < 0.01)
        #expect(abs(leftColor.blueComponent - rightColor.blueComponent) < 0.01)
    }

    @Test func shortcutsSettingsTabRenders() {
        let saved = SharedDefaults.store.string(forKey: "settingsTab")
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: "settingsTab")
            } else {
                SharedDefaults.store.removeObject(forKey: "settingsTab")
            }
        }
        SharedDefaults.store.set("shortcuts", forKey: "settingsTab")
        #expect(renders(SettingsPane(updater: smokeUpdater())))
    }

    @Test func permissionsPaneRenders() {
        #expect(renders(PermissionsPane()))
    }

    @Test func terminalPaneRenders() {
        #expect(renders(TerminalSettingsPane()))
    }

    @Test func terminalSmokeRenderDoesNotStartShell() {
        let session = MachineSession(
            machine: Machine(name: "This Mac", host: "localhost"), local: true)
        let holder = TerminalSessionHolder()
        #expect(renders(MachineTerminalTab(session: session, holder: holder)))
        #expect(!holder.started)
    }

    @Test func spaceTerminalWindowRendersWithoutStartingSessions() {
        let defaults = UserDefaults(
            suiteName: "space-terminal-smoke-\(UUID().uuidString)")!
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "main", pane: "p1", kind: "Codex", status: .working,
            title: "Build checkout", workspace: "edith", cwd: "/tmp")
        let model = HerdrSpaceWindowModel(
            space: HerdrAgentSpace(id: "edith", title: "edith", agents: [agent]),
            store: store)

        #expect(
            renders(
                HerdrSpaceView(model: model, store: store, launchEnabled: false),
                width: 1180, height: 760))
        #expect(model.tabs.flatMap(\.holders).allSatisfy { !$0.started })
        model.stopAll()
    }

    @Test func finderSmokeRenderDoesNotStartConnection() async throws {
        let session = MachineSession(
            machine: Machine(name: "Remote", host: "203.0.113.1"), local: false,
            observesWakeRequests: false)
        let model = FinderModel(session: session)
        #expect(renders(FinderPane(model: model)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state == .disconnected)
    }

    @Test func machineControlCenterRendersWithoutStartingCommands() async throws {
        let session = MachineSession(
            machine: Machine(name: "This Mac", host: "localhost"), local: true)
        #expect(
            renders(
                MachineControlCenterView(session: session),
                width: 360, height: 400))
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state == .disconnected)
    }

    @Test func terminalSettingsTabRenders() {
        let saved = SharedDefaults.store.string(forKey: "settingsTab")
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: "settingsTab")
            } else {
                SharedDefaults.store.removeObject(forKey: "settingsTab")
            }
        }
        SharedDefaults.store.set("terminal", forKey: "settingsTab")
        #expect(renders(SettingsPane(updater: smokeUpdater())))
    }

    @Test func updateSchedulePanelRenders() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smoke-update-checks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let updater = UpdaterModel(logURL: url)
        updater.recordCheck(kind: .automatic, outcome: .upToDate)
        updater.recordCheck(kind: .manual, outcome: .updateFound, version: "0.0.25")
        updater.recordCheck(kind: .automatic, outcome: .failed, detail: "Offline")
        #expect(updater.automaticCheckCount == 2)
        #expect(renders(UpdateSchedulePanel(updater: updater), width: 560, height: 640))
    }

    @Test func updateSchedulePanelRendersWithNoHistory() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smoke-update-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(
            renders(
                UpdateSchedulePanel(updater: UpdaterModel(logURL: url)),
                width: 560, height: 640))
    }

    @Test func permissionsSettingsTabRenders() {
        let saved = SharedDefaults.store.string(forKey: "settingsTab")
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: "settingsTab")
            } else {
                SharedDefaults.store.removeObject(forKey: "settingsTab")
            }
        }
        SharedDefaults.store.set("permissions", forKey: "settingsTab")
        #expect(renders(SettingsPane(updater: smokeUpdater())))
    }

    @Test func calendarPageRenders() {
        #expect(renders(CalendarPage()))
    }

    @Test func herdrPageRenders() {
        #expect(renders(HerdrPage(store: HerdrStore())))
    }

    @Test func herdrDiffFallsBackToTheQuinjetPicker() {
        let name = "herdr-quinjet-picker-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "main", pane: "p1", kind: "Codex", status: .working,
            title: "Build checkout", workspace: "edith", cwd: "/tmp")
        var tab = HerdrOpenTab(
            agent: agent, machine: nil, holder: TerminalSessionHolder(),
            quinjet: HerdrQuinjetSession())
        tab.view = .diff
        tab.quinjet.showsProjectPicker = true

        #expect(
            renders(
                HerdrSessionView(store: store, tab: tab, launchEnabled: false),
                width: 900, height: 700))
        tab.quinjet.stop()
    }

    @Test func herdrBoardWithAgentSpacesRenders() {
        let name = "herdr-board-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })
        let agent = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "main", pane: "p1", kind: "Codex",
            status: .working, title: "Build checkout", workspace: "edith", cwd: "/tmp")
        store.apply([.local(herdrPresent: true, agents: [agent])])
        store.spaceGroupingEnabled = true
        store.selectBoard()

        #expect(renders(HerdrPage(store: store), width: 1180, height: 760))
    }

    @Test func musicPageRenders() {
        #expect(renders(MusicPage()))
    }

    @Test func titlebarChromeRenders() {
        #expect(renders(TitlebarChrome(height: 52, width: 200), width: 220, height: 60))
    }

    @Test func herdrTitlebarViewPickerRenders() {
        #expect(
            renders(
                HerdrTitlebarViewPicker(store: HerdrStore(), agentID: "agent"),
                width: 280, height: 40))
    }

    @Test func herdrTitlebarViewPickerReflectsDetailVisibility() throws {
        let name = "UISmokeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in })
        let visible = try #require(
            renderedBitmap(
                HerdrTitlebarViewPicker(store: store, agentID: "agent"),
                width: 280, height: 40)
        ).representation(using: .png, properties: [:])
        store.detailOpen = false
        let hidden = try #require(
            renderedBitmap(
                HerdrTitlebarViewPicker(store: store, agentID: "agent"),
                width: 280, height: 40)
        ).representation(using: .png, properties: [:])
        #expect(visible != hidden)
    }

    @Test func herdrTitlebarViewPickerRendersEveryThemeDistinctly() throws {
        let key = AppStorageKeys.General.theme
        let saved = SharedDefaults.store.object(forKey: key)
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }
        var appearances = Set<Data>()
        for theme in AppTheme.allCases {
            SharedDefaults.store.set(theme.rawValue, forKey: key)
            let bitmap = try #require(
                renderedBitmap(
                    HerdrTitlebarViewPicker(store: HerdrStore(), agentID: "agent"),
                    width: 280, height: 40))
            appearances.insert(try #require(bitmap.representation(using: .png, properties: [:])))
        }
        #expect(appearances.count == AppTheme.allCases.count)
    }

    @Test func herdrViewPickerUsesTheRightTitlebarAccessory() throws {
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable])
        defer { window.orderOut(nil) }

        HerdrAgentWindow.addViewControls(
            to: window, store: HerdrStore(), agentID: "agent")

        let accessory = try #require(window.titlebarAccessoryViewControllers.first)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(accessory.layoutAttribute == .right)
        #expect(
            abs(accessory.view.frame.width - HerdrAgentWindow.viewControlsWidth) < 0.5)
        #expect(accessory.view.frame.height >= 28)
        #expect(accessory.view.fittingSize.width >= HerdrAgentWindow.viewControlsContentWidth)
        #expect(accessory.view.fittingSize.height <= 36)
    }

    @Test func panelTabBarRenders() {
        let tabs: [(id: String, title: String)] = allTabs.map { ($0.id, $0.title) }
        #expect(
            renders(
                TabBar(tabs: tabs, selection: .constant("usage"), theme: .orange),
                width: 480, height: 60))
    }
}
