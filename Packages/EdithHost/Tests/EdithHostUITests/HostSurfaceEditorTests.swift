import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized) struct HostSurfaceEditorTests {
    @Test func marketplaceRestoresSuiteGroupsSearchAndOriginalArtworkWithoutStartingWorkers()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let entries = fixture.marketplace.entries
        #expect(
            HostMarketplaceCatalog.suites.map(\.id) == [
                "agents", "maintenance", "system", "desk", "media", "data", "tools",
            ])
        #expect(Set(entries.map(\.id)) == Set(HostMarketplaceCatalog.subtitles.keys))
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "   clipboard  ", category: "media").map(
                \.id) == ["clipboard", "colorPicker"])
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "", category: "media").allSatisfy {
                $0.category == "media"
            })
        for theme in AppTheme.allCases {
            let images = HostMarketplaceArtwork.swatches(theme: theme.rawValue)
            #expect(images.count == 4)
            #expect(images.allSatisfy { $0.size == NSSize(width: 84, height: 50) })
        }
        #expect(HostMarketplaceArtwork.image("unknown") == nil)
        #expect(!HostExtensionPreviewMotionPolicy.animates(hovering: true, reduceMotion: true))
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: MarketplacePage(marketplace: fixture.marketplace)
                .environment(\.compactLayout, false).environment(
                    \.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 850)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "Extensions") != nil)
        #expect(find(host, label: "Agents suite enabled") != nil)
        #expect(
            find(host, label: "Search extensions") != nil
                || find(host, label: "Find extensions") != nil)
        #expect(
            find(host, label: "Claude, Codex and Cursor limits, usage stats, and alerts.") != nil)
        #expect(find(host, label: "Download") != nil)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test(arguments: [false, true])
    func suiteDisableRetainsSelectionsWithoutDownloadOrRestartAndReenableIsExplicit(
        rejectDisable: Bool
    ) async throws {
        let fixture = try SuiteFixture(rejectDisable: rejectDisable)
        defer { fixture.clean() }
        let suite = try #require(HostMarketplaceCatalog.suites.first { $0.id == "system" })
        let selection = HostSuiteSelection(
            marketplace: fixture.marketplace, defaults: fixture.defaults)
        for id in ["keepAwake", "lidAwake", "clipboard"] {
            await fixture.marketplace.enable(id: id)
        }
        #expect(fixture.marketplace.sessions.activeIDs == ["keepAwake", "lidAwake", "clipboard"])
        let old = fixture.marketplace.sessions.processIdentifiers
        await selection.setEnabled(false, suite: suite)
        #expect(!selection.enabled(suite))
        #expect(fixture.marketplace.sessions.activeIDs == ["clipboard"])
        #expect(fixture.marketplace.sessions.processIdentifiers["clipboard"] == old["clipboard"])
        #expect(
            fixture.defaults.stringArray(forKey: suite.defaultsKey + "Selections") == [
                "keepAwake", "lidAwake",
            ])
        #expect(
            HostSuiteSelection(marketplace: fixture.marketplace, defaults: fixture.defaults)
                .enabled(suite) == false)
        #expect(fixture.marketplace.downloadedIDs == ["keepAwake", "lidAwake", "clipboard"])
        if rejectDisable {
            #expect(fixture.marketplace.sessions.pendingDisableIDs == ["lidAwake"])
            #expect(fixture.marketplace.sessions.processIdentifiers["lidAwake"] == old["lidAwake"])
        } else {
            #expect(fixture.marketplace.sessions.processIdentifiers.count == 1)
            for id in ["keepAwake", "lidAwake"] { #expect(kill(try #require(old[id]), 0) == -1) }
        }
        await selection.setEnabled(true, suite: suite)
        #expect(selection.enabled(suite))
        #expect(fixture.marketplace.sessions.activeIDs == ["keepAwake", "lidAwake", "clipboard"])
        #expect(fixture.marketplace.sessions.pendingDisableIDs.isEmpty)
        #expect(fixture.marketplace.sessions.processIdentifiers["keepAwake"] != old["keepAwake"])
        if rejectDisable { #expect(await fixture.marketplace.sessions.shutdown() == false) }
        #expect(await fixture.marketplace.sessions.shutdown())
    }

    @Test func generalSettingsKeepOriginalControlsAndExecuteOwnedActions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let defaults = try #require(
            UserDefaults(suiteName: fixture.marketplace.identity.defaultsSuite))
        let restore = enableAccessibility()
        defer { restore() }
        var openedPermissions = false
        var openedWelcome = false
        var dockValues: [Bool] = []
        let permissions = HostPermissions(
            environment: .init(read: { [:] }, request: { _ in }, openSettings: { _ in false }))
        let host = NSHostingView(
            rootView: HostSettingsPage(
                marketplace: fixture.marketplace,
                permissions: permissions, defaults: defaults,
                openPermissions: { openedPermissions = true },
                showWelcome: { openedWelcome = true }, activation: { dockValues.append($0) }
            )
            .environment(\.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: 960, height: 1000)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let blue = try #require(find(host, label: "Blue theme"))
        #expect((blue as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(defaults.string(forKey: AppStorageKeys.General.theme) == "blue")
        #expect(defaults.string(forKey: AppStorageKeys.General.lastPaletteTheme) == "blue")
        let access = try #require(find(host, label: "Permissions"))
        #expect((access as AnyObject).accessibilityPerformPress?() == true)
        #expect(openedPermissions)
        let welcome = try #require(find(host, label: "Show welcome tour"))
        #expect((welcome as AnyObject).accessibilityPerformPress?() == true)
        #expect(openedWelcome)
        let dock = try #require(find(host, label: "Show Dock icon"))
        _ = (dock as AnyObject).accessibilityPerformPress?()
        await settle(window, host: host)
        #expect(defaults.bool(forKey: AppStorageKeys.General.showDockIcon) == false)
        #expect(dockValues == [false])
        #expect(find(host, label: "⌥⌘E") != nil)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test func aboutRestoresOriginalIdentityStoryAndRepositoryWithoutAutomaticRequests()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: HostAboutPage(identity: fixture.marketplace.identity)
                .environment(\.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 850)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "Edith") != nil)
        #expect(find(host, label: "pulkitxm/edith") != nil)
        #expect(
            find(host, label: "Every little Mac utility you'd otherwise pay for, under one roof.")
                != nil)
        #expect(find(host, label: "Made with ♥ by Pulkit") != nil)
        #expect(HostBrand.github != nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.marketplace.identity.root.appendingPathComponent(
                    "Caches/contributors.json"
                ).path))
        #expect(await fixture.requests.count == 0)
    }

    @Test func permissionsRetainCatalogRequirementsAndHonorExplicitRequestOwnership() async throws {
        let entries = try HostIndex.bundled()
        var requested: [HostPermission] = []
        var reads = 0
        let permissions = HostPermissions(
            environment: .init(
                read: {
                    reads += 1; return [.camera: true]
                },
                request: { requested.append($0) }, openSettings: { _ in true }))
        let initial = permissions.usages(
            entries: entries, activeIDs: ["calendar", "virtualCamera"])
        #expect(HostPermissionCatalog.grantable(initial).map(\.permission) == [.calendar, .camera])
        await permissions.request(.camera)
        #expect(requested == [.camera])
        #expect(reads == 1)
        #expect(permissions.requesting == nil)
        let current = permissions.usages(
            entries: entries, activeIDs: ["calendar", "virtualCamera"])
        #expect(HostPermissionCatalog.grantable(current).map(\.permission) == [.calendar])
        await permissions.request(.bluetooth)
        #expect(requested == [.camera])
        #expect(permissions.openSettings(.automation) == false)
        #expect(permissions.openSettings(.camera) == true)
        let stopped = permissions.usages(entries: entries, activeIDs: [])
        #expect(HostPermissionCatalog.filter(stopped, by: .mine).isEmpty)
        #expect(HostPermissionCatalog.grantable(stopped).isEmpty)
    }

    @Test func permissionsUIKeepsOriginalFiltersAndInactiveExtensionDiscovery() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        var opened = false
        var requests = 0
        let permissions = HostPermissions(
            environment: .init(
                read: { [:] }, request: { _ in requests += 1 }, openSettings: { _ in false }))
        let host = NSHostingView(
            rootView: HostPermissionsPane(
                marketplace: fixture.marketplace, permissions: permissions,
                openExtensions: { opened = true }
            )
            .environment(\.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 850)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "My extensions") != nil)
        #expect(find(host, label: "All permissions") != nil)
        #expect(find(host, label: "Needs attention") != nil)
        #expect(find(host, label: "No enabled extension needs access yet") != nil)
        let browse = try #require(find(host, label: "Browse Extensions"))
        #expect((browse as AnyObject).accessibilityPerformPress?() == true)
        #expect(opened)
        #expect(requests == 0)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
    }

    @Test func contributorAdmissionRejectsUnboundedOrForeignDestinationsAndKeepsBotFiltering()
        throws
    {
        let values = [
            HostContributor(
                id: 1, login: "sample-one",
                avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1")!,
                profileURL: URL(string: "https://github.com/sample-one")!, contributions: 10),
            HostContributor(
                id: 2, login: "sample-bot[bot]",
                avatarURL: URL(string: "https://avatars.githubusercontent.com/u/2")!,
                profileURL: URL(string: "https://github.com/sample-bot")!, contributions: 20),
        ]
        #expect(
            try HostContributors.people(from: JSONEncoder().encode(values)).map(\.login) == [
                "sample-one"
            ])
        #expect(throws: (any Error).self) {
            try HostContributors.people(
                from: Data(repeating: 1, count: HostContributors.byteLimit + 1))
        }
        let foreign = HostContributor(
            id: 3, login: "sample",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/3")!,
            profileURL: URL(string: "https://example.com/sample")!, contributions: 1)
        #expect(throws: (any Error).self) {
            try HostContributors.people(from: JSONEncoder().encode([foreign]))
        }
    }

    @Test func updateHistoryPersistsBoundedOriginalRecordsAndClearsItsOwnedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("update-checks.json")
        let updater = HostUpdater(startingUpdater: false, logURL: log)
        for index in 0..<205 {
            updater.recordCheck(
                kind: .automatic, outcome: .upToDate,
                date: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(updater.checkHistory.count == 200)
        #expect(updater.automaticCheckCount == 200)
        let restored = HostUpdateCheckLog.load(from: log)
        #expect(restored.count == 200)
        #expect(restored.first?.date == Date(timeIntervalSince1970: 204))
        #expect(restored.last?.date == Date(timeIntervalSince1970: 5))
        #expect(HostUpdateCheckInterval.clamp(1) == 3600)
        #expect(HostUpdateCheckInterval.clamp(.infinity) == 86400)
        #expect(HostUpdateCheckInterval.clamp(4_000_000) == 2_592_000)
        updater.clearCheckHistory()
        await Task.yield()
        #expect(updater.checkHistory.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(updater.available == false)
    }

    @Test func recordedShortcutPreservesEstablishedModifierOrderAndRejectsUnmodifiedKeys() {
        #expect(
            HostRecordedShortcut(
                code: 49, flags: [.control, .option, .shift, .command], characters: " ")?.label
                == "⌃⌥⇧⌘Space")
        #expect(
            HostRecordedShortcut(code: 14, flags: [.option, .command], characters: "e")?.label
                == "⌥⌘E")
        #expect(HostRecordedShortcut(code: 14, flags: [], characters: "e") == nil)
        #expect(HostExtensionShortcut.micMute.prefix == "micHotKey")
    }

    @Test func mainWindowFramesPreserveOriginalScreenBoundsAndAutosaveRepair() {
        let regular = NSRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(
            HostWindowFramePolicy.minimumSize(visibleFrame: regular)
                == NSSize(width: 960, height: 640))
        #expect(
            HostWindowFramePolicy.defaultSize(visibleFrame: regular)
                == NSSize(width: 1180.8, height: 702))
        let compact = NSRect(x: -800, y: 30, width: 800, height: 500)
        #expect(HostWindowFramePolicy.minimumSize(visibleFrame: compact) == compact.size)
        #expect(HostWindowFramePolicy.defaultSize(visibleFrame: compact) == compact.size)
        let oversized = HostWindowFramePolicy.normalizedFrame(
            NSRect(x: 9000, y: 9000, width: 2000, height: 1800), visibleFrame: compact)
        #expect(oversized == compact)
        let repaired = HostWindowFramePolicy.normalizedFrame(
            NSRect(x: -900, y: 0, width: 200, height: 100), visibleFrame: compact)
        #expect(repaired == compact)
        #expect(HostWindowFramePolicy.shouldDiscardAutosave("tilingState=fullscreen"))
        #expect(!HostWindowFramePolicy.shouldDiscardAutosave("0 0 1240 820"))
        #expect(
            HostWindowFramePolicy.autosaveKey(name: "EdithMainWindow")
                == "NSWindow Frame EdithMainWindow")
    }

    @Test func mainNavigationPreservesEstablishedDestinationOrderAndSections() {
        #expect(
            HostNavigationCatalog.pages.map(\.id) == [
                "home", "machines", "docs", "agents", "dashboard", "herdr", "quinjet", "companion",
                "plugins",
                "appMaintenance", "blitztree", "system", "runningApps", "desk", "media", "studio",
                "latex",
                "timeLapse", "downloads", "music", "calendar", "virtualCamera", "data", "database",
                "attention",
                "seoAudit", "codeStats", "extensions", "settings", "about",
            ])
        #expect(
            HostNavigationCatalog.settings.map(\.id) == [
                "general", "surfaces", "agentActivity", "permissions", "agent", "jev", "data",
                "shortcuts", "terminal", "icloud", "updates",
            ])
        #expect(
            HostNavigationCatalog.maintenance.map(\.id) == [
                "Updates", "Packages", "Remove", "Cleaner", "History",
            ])
        #expect(HostNavigationCatalog.page("dashboard").extensionID == "usage")
        #expect(HostNavigationCatalog.page("runningApps").extensionID == "system")
    }

    @Test func mainNavigationHonorsExplicitSuiteSelectionAndFallsBackAfterDisable() throws {
        let name = "com.pulkit.edith.tests.navigation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(
            HostNavigationCatalog.resolve("calendar", active: ["calendar"], defaults: defaults)
                == "calendar")
        defaults.set(false, forKey: AppStorageKeys.Suites.media)
        #expect(
            HostNavigationCatalog.resolve("calendar", active: ["calendar"], defaults: defaults)
                == "home")
        defaults.set(true, forKey: AppStorageKeys.Suites.media)
        #expect(HostNavigationCatalog.resolve("calendar", active: [], defaults: defaults) == "home")
        #expect(
            HostNavigationCatalog.resolve("machines", active: [], defaults: defaults) == "machines")
        #expect(HostNavigationCatalog.resolve("missing", active: [], defaults: defaults) == "home")
        defaults.set(false, forKey: AppStorageKeys.General.settingsCategoriesExpanded)
        #expect(
            !HostNavigationCatalog.expanded(
                HostNavigationCatalog.page("settings"), defaults: defaults))
    }

    @Test func mainShellShowsOriginalCoreAndAppNavigationWithoutStartingExtensions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: HostWorkspace(
                marketplace: fixture.marketplace, defaults: fixture.marketplace.surfaces.preferences
            ).environment(\.automaticViewActionsEnabled, false).environment(
                \.surfaceSampleContent, true))
        host.frame = CGRect(x: 0, y: 0, width: 1240, height: 850)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        for title in ["Home", "Fleet", "Docs", "Extensions", "Settings", "About", "Toggle sidebar"]
        {
            #expect(find(host, label: title) != nil)
        }
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
        #expect(window.titleVisibility == .hidden)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test func originalHomeLayoutControlsChangeLayoutAndOpenItsEditorWithoutStartingWorkers()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        fixture.marketplace.surfaceLayouts.update(.home) { $0.balancedRows = false }
        var editorOpened = false
        let host = NSHostingView(
            rootView: HostHomePage(
                marketplace: fixture.marketplace, customize: { editorOpened = true }, extensions: {}
            ).environment(\.automaticViewActionsEnabled, false).environment(
                \.surfaceSampleContent, true))
        host.frame = CGRect(x: 0, y: 0, width: 1240, height: 850)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let fit = try #require(find(host, label: "Auto fit"))
        #expect((fit as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.surfaceLayouts.home.balancedRows == true)
        let edit = try #require(find(host, label: "Edit layout"))
        #expect((edit as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(find(host, label: "Done") != nil)
        let editor = try #require(find(host, label: "Widget editor"))
        #expect((editor as AnyObject).accessibilityPerformPress?() == true)
        #expect(editorOpened)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test func emptyHomeRendersOnlyTheBuiltInClockAndOffersExtensionDiscovery() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: HostHomePage(marketplace: fixture.marketplace, customize: {}, extensions: {})
                .environment(\.surfaceSampleContent, true)
                .environment(\.compactLayout, false).environment(
                    \.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "World clocks") != nil)
        #expect(find(host, label: "Widget editor") != nil)
        #expect(find(host, label: "Auto fit") != nil)
        #expect(find(host, label: "Edit layout") != nil)
        #expect(find(host, label: "Meetings") == nil)
        #expect(find(host, label: "Open Calendar") == nil)
        #expect(fixture.marketplace.surfaces.requests.pendingCount == 0)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test func sharedCardRendererShowsRealContractDataAndDispatchesOnlyItsActionID() async throws {
        let restore = enableAccessibility()
        defer { restore() }
        let action = SurfaceAction("join:synthetic-meeting", "Join", "video.fill", field: "join")
        let snapshot = SurfaceSnapshot(
            providerID: "calendar",
            rows: [
                .init(
                    "synthetic-meeting", sourceID: "synthetic-calendar",
                    title: "Synthetic design review", detail: "Synthetic calendar", value: "10:00",
                    icon: "calendar", actions: [action])
            ])
        var performed: [String] = []
        let host = NSHostingView(
            rootView: SurfaceSnapshotContent(
                tile: .init(.calendar), snapshot: snapshot, perform: { performed.append($0.id) }
            ).padding(16).frame(width: 420))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 240)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "Synthetic design review") != nil)
        let join = try #require(find(host, label: "Join"))
        #expect((join as AnyObject).accessibilityPerformPress?() == true)
        #expect(performed == ["join:synthetic-meeting"])
        var hidden = SurfaceTile(.calendar)
        hidden.hiddenFields = ["join"]
        let restricted = NSHostingView(
            rootView: SurfaceSnapshotContent(
                tile: hidden, snapshot: snapshot,
                perform: { _ in Issue.record("Hidden action was executed") }))
        restricted.frame = host.frame
        window.contentView = restricted
        await settle(window, host: restricted)
        #expect(find(restricted, label: "Join") == nil)
    }

    @Test func selectingAWidgetRetainsCanvasGeometryAndNeverStartsAnExtension() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let editor = HostSurfaceEditor(marketplace: fixture.marketplace)
        let host = NSHostingView(
            rootView: editor.environment(\.compactLayout, false)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let first = try #require(find(host, label: "Move World clocks"))
        let before = try #require((first as AnyObject).accessibilityFrame?())
        fixture.marketplace.surfaces.preferences.set("clocks", forKey: "surfaceEditorWidget")
        await settle(window, host: host)
        let selected = try #require(find(host, label: "Move World clocks"))
        let after = try #require((selected as AnyObject).accessibilityFrame?())
        #expect(find(host, label: "Lock layout") != nil)
        #expect(abs(before.minX - after.minX) < 1)
        #expect(abs(before.width - after.width) < 1)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test func addingADownloadableWidgetSavesItsLayoutWithoutDownloadingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        fixture.marketplace.surfaceLayouts.update(.home) { $0.tiles = [] }
        let host = NSHostingView(
            rootView: HostSurfaceEditor(marketplace: fixture.marketplace)
                .environment(\.compactLayout, false)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        let add = try #require(find(host, label: "Add Meetings"))
        #expect((add as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.surfaceLayouts.home.tiles.map(\.widget) == [.calendar])
        #expect(find(host, label: "Download") != nil)
        let restored = SurfaceLayoutStore(defaults: fixture.marketplace.surfaces.preferences)
        #expect(restored.home == fixture.marketplace.surfaceLayouts.home)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test func bothEditorsRenderAtCompactRegularAndZoomedSizes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for target in SurfaceTarget.allCases {
            fixture.marketplace.surfaces.preferences.set(
                target.rawValue, forKey: "surfaceEditorTarget")
            for variant in [
                Variant("regular-light", 1200, 1, .light), Variant("regular-dark", 1200, 1, .dark),
                Variant("compact", 620, 1, .light), Variant("zoomed", 1200, 1.5, .dark),
            ] {
                UIScale.apply(variant.zoom)
                let host = NSHostingView(
                    rootView: HostSurfaceEditor(marketplace: fixture.marketplace)
                        .environment(\.compactLayout, variant.width < UIScale.pt(720))
                        .environment(\.colorScheme, variant.scheme)
                        .environment(\.automaticViewActionsEnabled, false)
                        .transaction { $0.animation = nil })
                host.frame = CGRect(x: 0, y: 0, width: variant.width, height: 900)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host
                window.orderBack(nil)
                await settle(window, host: host)
                #expect(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                #expect(abs(host.bounds.width - variant.width) < 1)
                let visible = window.convertToScreen(host.convert(host.bounds, to: nil))
                for label in ["Home", "Notch", "Grid", "Layouts"] {
                    let control = try #require(find(host, label: label))
                    let frame = try #require((control as AnyObject).accessibilityFrame?())
                    #expect(visible.insetBy(dx: -1, dy: -1).contains(frame))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                if let capture = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
                {
                    let directory = URL(fileURLWithPath: capture, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(
                        to: directory.appendingPathComponent(
                            "\(target.rawValue)-\(variant.name).png"), options: .atomic)
                }
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                window.orderOut(nil)
            }
        }
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    private struct Variant {
        let name: String
        let width: Double
        let zoom: Double
        let scheme: ColorScheme
        init(_ name: String, _ width: Double, _ zoom: Double, _ scheme: ColorScheme) {
            self.name = name; self.width = width; self.zoom = zoom; self.scheme = scheme
        }
    }

    @Test(arguments: [true, false])
    func pendingDisableExplainsInactiveCardsAndOffersExplicitRecoveryActions(compact: Bool)
        async throws
    {
        let fixture = try Fixture(pendingDisableID: "calendar")
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: MarketplacePage(marketplace: fixture.marketplace)
                .frame(width: compact ? 600 : 1100, height: 650)
                .environment(\.compactLayout, compact).environment(
                    \.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: compact ? 600 : 1100, height: 650)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(find(host, label: "Disable pending · 1.0.0") != nil)
        #expect(find(host, label: "Enabled · 1.0.0") == nil)
        #expect(find(host, label: "Disabled · 1.0.0") == nil)
        #expect(
            find(
                host,
                label:
                    "Cleanup is still pending. Home and Notch cards are inactive. System resources may remain until cleanup or macOS approval finishes."
            ) != nil)
        let retry = try #require(find(host, label: "Retry disable"))
        #expect((retry as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.sessions.pendingDisableIDs == ["calendar"])
        #expect(fixture.marketplace.error != nil)
        #expect(fixture.marketplace.surfaceAvailability.activeIDs.isEmpty)
        let enable = try #require(find(host, label: "Enable instead"))
        #expect((enable as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.sessions.pendingDisableIDs == ["calendar"])
        #expect(fixture.marketplace.sessions.states["calendar"] == .failed)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(find(host, label: "Disable pending · 1.0.0") != nil)
        #expect(find(host, label: "Retry disable") != nil)
        #expect(fixture.marketplace.error?.contains("Cleanup is pending") == true)
        #expect(fixture.marketplace.surfaceAvailability.activeIDs.isEmpty)
        #expect(await fixture.requests.count == 0)
    }

    @Test(arguments: [true, false], ["abi", "os", "removal"])
    func incompatibleAndPendingPackagesKeepRemoveAndActualStorageAccounting(
        compact: Bool, state: String
    ) async throws {
        let fixture = try Fixture(packageState: state)
        defer { fixture.clean() }
        let restore = enableAccessibility()
        defer { restore() }
        let host = NSHostingView(
            rootView: MarketplacePage(marketplace: fixture.marketplace)
                .frame(width: compact ? 600 : 1100, height: 650)
                .environment(\.compactLayout, compact).environment(
                    \.automaticViewActionsEnabled, false))
        host.frame = CGRect(x: 0, y: 0, width: compact ? 600 : 1100, height: 650)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle(window, host: host)
        #expect(fixture.marketplace.installed["calendar"] == nil)
        #expect(fixture.marketplace.installedVersions["calendar"]?.count == 1)
        #expect(
            find(host, label: state == "removal" ? "Removal pending" : "Needs a compatible update")
                != nil)
        #expect(find(host, label: "Not installed") == nil)
        #expect(find(host, label: "Enable") == nil)
        let bytes = fixture.marketplace.installedBytes
        #expect(bytes >= 128)
        fixture.heldLease?.close()
        let remove = try #require(find(host, label: "Remove"))
        #expect((remove as AnyObject).accessibilityPerformPress?() == true)
        await settle(window, host: host)
        #expect(fixture.marketplace.installedVersions["calendar"] == nil)
        #expect(!fixture.marketplace.downloadedIDs.contains("calendar"))
        #expect(!fixture.marketplace.pendingRemovalIDs.contains("calendar"))
        #expect(fixture.marketplace.installedBytes < bytes)
        #expect(find(host, label: "Not installed") != nil)
        #expect(find(host, label: "Download") != nil)
        #expect(find(host, label: "Remove") == nil)
        #expect(fixture.marketplace.sessions.processIdentifiers.isEmpty)
        #expect(fixture.marketplace.error == nil)
        #expect(await fixture.requests.count == 0)
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        let isControl =
            label != "Show Dock icon" || (node as AnyObject).accessibilityRole?() == .checkBox
        if isControl, (node as AnyObject).accessibilityLabel?() == label { return node }
        let valueSelector = NSSelectorFromString("accessibilityValue")
        if isControl, node.responds(to: valueSelector),
            node.perform(valueSelector)?.takeUnretainedValue() as? String == label
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = find(child, label: label, depth: depth + 1) { return result }
        }
        if let view = node as? NSView {
            for child in view.subviews {
                if let result = find(child, label: label, depth: depth + 1) { return result }
            }
        }
        return nil
    }

    private func enableAccessibility() -> () -> Void {
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        return {
            for (attribute, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
    }

    private func settle(_ window: NSWindow, host: NSView) async {
        for _ in 0..<8 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private actor Requests {
        private(set) var count = 0
        func reject() throws -> Data {
            count += 1
            throw MarketplaceError.downloadFailed
        }
    }

    @MainActor private struct SuiteFixture {
        let directory: URL
        let marketplace: HostMarketplace
        let defaults: UserDefaults

        init(rejectDisable: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.suites-\(UUID().uuidString)",
                supportDirectory: directory)
            defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            try FileManager.default.createDirectory(
                at: store.root, withIntermediateDirectories: true)
            var packages: [ExtensionPackage] = []
            for id in ["keepAwake", "lidAwake", "clipboard"] {
                let package = ExtensionPackage(
                    id: id, version: "1.0.0", hostABI: HostContract.compatibility,
                    downloadURL: URL(
                        string:
                            "https://github.com/pulkitxm/edith/releases/download/synthetic/\(id).zip"
                    )!,
                    sha256: String(repeating: "a", count: 64), downloadBytes: 128,
                    installedBytes: 128)
                try FileManager.default.createDirectory(
                    at: store.directory(for: package), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 128).write(
                    to: store.directory(for: package).appendingPathComponent("synthetic-payload"))
                packages.append(package)
            }
            try store.commit(packages)
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EdithHostCoreTests/Fixtures/worker.py")
            let sessions = HostExtensionSessions(defaults: defaults) { package in
                HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [
                        script.path,
                        rejectDisable && package.id == "lidAwake"
                            ? "reject-disable-once" : "normal",
                    ], requestTimeout: .seconds(2))
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: Data(repeating: 0, count: 32),
                repository: MarketplaceConfiguration.repository,
                cache: directory.appendingPathComponent("catalog.json"),
                fetch: { _ in
                    Issue.record("Suite actions must not fetch the catalog");
                    throw MarketplaceError.downloadFailed
                })
            let installer = ExtensionPackageInstaller(
                store: store,
                download: { _, _ in
                    Issue.record("Suite actions must not download packages");
                    throw MarketplaceError.downloadFailed
                },
                verify: { _ in throw MarketplaceError.invalidSignature })
            marketplace = try HostMarketplace(
                identity: identity,
                entries: try HostIndex.bundled().filter {
                    ["keepAwake", "lidAwake", "clipboard"].contains($0.id)
                },
                store: store, catalogClient: client, installer: installer, sessions: sessions)
        }
        func clean() {
            defaults.removePersistentDomain(forName: marketplace.identity.defaultsSuite)
            marketplace.surfaces.navigation.shutdown(); marketplace.surfaces.requests.shutdown();
            marketplace.surfaces.privacy.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor private struct Fixture {
        let directory: URL
        let marketplace: HostMarketplace
        let requests = Requests()
        let heldLease: PackageFileLock?

        init(pendingDisableID: String? = nil, packageState: String? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.surface-editor-\(UUID().uuidString)",
                supportDirectory: directory)
            let store = ExtensionPackageStore(
                root: identity.root.appendingPathComponent("Extensions"))
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let fixtureID = pendingDisableID ?? (packageState == nil ? nil : "calendar")
            var lease: PackageFileLock?
            if let id = fixtureID {
                try FileManager.default.createDirectory(
                    at: store.root, withIntermediateDirectories: true)
                if pendingDisableID != nil {
                    defaults.set([id], forKey: "enabledExtensions")
                    defaults.set([id], forKey: "pendingDisableExtensions")
                }
                let package = ExtensionPackage(
                    id: id, version: "1.0.0",
                    hostABI: packageState == "abi" || packageState == "removal"
                        ? "incompatible-fixture" : HostContract.compatibility,
                    minimumSystemVersion: packageState == "os"
                        ? ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1 : 14,
                    downloadURL: URL(
                        string:
                            "https://github.com/pulkitxm/edith/releases/download/synthetic/fixture.zip"
                    )!,
                    sha256: String(repeating: "a", count: 64), downloadBytes: 128,
                    installedBytes: 128)
                try FileManager.default.createDirectory(
                    at: store.directory(for: package), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 128).write(
                    to: store.directory(for: package).appendingPathComponent("synthetic-payload"))
                try store.commit([package])
                if packageState == "removal" {
                    lease = try store.lease(package)
                    #expect(try store.requestRemoval(id: id) == false)
                }
            }
            heldLease = lease
            let sessions = HostExtensionSessions(defaults: defaults) { _ in
                throw HostWorkerError.rejected
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: Data(repeating: 0, count: 32),
                repository: MarketplaceConfiguration.repository,
                cache: directory.appendingPathComponent("catalog.json"),
                fetch: { [requests] _ in try await requests.reject() })
            let installer = ExtensionPackageInstaller(
                store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                verify: { _ in throw MarketplaceError.invalidSignature })
            marketplace = try HostMarketplace(
                identity: identity,
                entries: try HostIndex.bundled().filter {
                    fixtureID == nil || $0.id == fixtureID
                }, store: store,
                catalogClient: client, installer: installer, sessions: sessions)
        }

        func clean() {
            heldLease?.close()
            let identity = marketplace.identity
            marketplace.surfaces.navigation.shutdown()
            marketplace.surfaces.requests.shutdown()
            marketplace.surfaces.privacy.shutdown()
            UserDefaults(suiteName: identity.identifier)?.removePersistentDomain(
                forName: identity.identifier)
            UserDefaults(suiteName: identity.defaultsSuite)?.removePersistentDomain(
                forName: identity.defaultsSuite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
