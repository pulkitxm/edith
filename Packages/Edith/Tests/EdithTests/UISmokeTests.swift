import AppKit
import EdithKit
import SwiftUI
import Testing
@testable import Edith
@testable import EdithHelper

@MainActor
private func renders(_ view: some View, width: CGFloat = 900, height: CGFloat = 700) -> Bool {
    let host = NSHostingView(
        rootView:
            view
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.companionRequestsEnabled, false)
            .environment(\.machineConnectionsEnabled, false)
            .environment(\.terminalLaunchEnabled, false))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.pixelsWide > 0 && rep.pixelsHigh > 0
}

@MainActor private func smokeUpdater() -> UpdaterModel {
    UpdaterModel(
        logURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edith-smoke-\(UUID().uuidString).json"))
}

@MainActor @Suite(.serialized) struct UISmokeTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func loadingSkeletonsRender() {
        #expect(renders(MachineOverviewSkeleton(dark: true)))
        #expect(renders(FleetHomeSkeleton(dark: true)))
        #expect(renders(ListRowsSkeleton(rows: 4, dark: true)))
        #expect(renders(FinderSkeleton(mode: .list, dark: true)))
        #expect(renders(FinderSkeleton(mode: .icon, dark: true)))
        #expect(renders(MetricCardSkeleton(dark: false), width: 300, height: 160))
    }

    @Test func homePageRenders() {
        #expect(renders(HomePage()))
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

    @Test func finderSmokeRenderDoesNotStartConnection() async throws {
        let session = MachineSession(
            machine: Machine(name: "Remote", host: "203.0.113.1"), local: false,
            observesWakeRequests: false)
        let model = FinderModel(session: session)
        #expect(renders(FinderPane(model: model)))
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

    @Test func musicPageRenders() {
        #expect(renders(MusicPage()))
    }

    @Test func titlebarChromeRenders() {
        #expect(renders(TitlebarChrome(height: 52, width: 200), width: 220, height: 60))
    }

    @Test func panelTabBarRenders() {
        let tabs: [(id: String, title: String)] = allTabs.map { ($0.id, $0.title) }
        #expect(
            renders(
                TabBar(tabs: tabs, selection: .constant("usage"), theme: .orange),
                width: 480, height: 60))
    }
}
