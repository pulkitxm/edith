import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostSurfaceAvailabilityTests {
    @Test func emptyApplicationHasOnlyBuiltInClockAndStartsNoSurfaceWork() throws {
        let availability = try fixture()
        for target in SurfaceTarget.allCases {
            let layout = SurfaceLayout.standard(target)
            #expect(availability.queryIDs(layout, target: target, visible: true).isEmpty)
            let visible = availability.projected(layout, target: target).tiles.map(\.widget)
            #expect(visible == (target == .home ? [.clocks] : []))
        }
        #expect(SurfaceNotchTab.visible(layout: .standard(.notch), activeIDs: []).isEmpty)
    }

    @Test func everyIndexedExtensionHasAnIndependentLibraryEntry() throws {
        let entries = try HostIndex.bundled()
        let widgets = SurfaceWidget.library(extensionIDs: entries.map(\.id))
        for entry in entries {
            #expect(widgets.contains { $0.providerIDs.contains(entry.id) })
        }
        #expect(Set(widgets.map(\.rawValue)).count == widgets.count)
    }

    @Test func downloadedPayloadsAndRememberedEnablementAreNotRunningExtensions() throws {
        let availability = try fixture(
            installed: ["music", "calendar"], downloaded: ["music", "calendar", "usage"],
            states: ["music": .disabled, "calendar": .starting, "usage": .active])
        #expect(availability.status(.music) == .disabled)
        #expect(availability.status(.calendar) == .starting)
        #expect(availability.status(.usage) == .needsCompatibleUpdate)
        #expect(availability.status(.agents) == .needsDownload)
        #expect(availability.activeIDs.isEmpty)
    }

    @Test func compositeCardsQueryOnlyTheirRunningProviders() throws {
        let availability = try fixture(
            installed: ["keepAwake", "colorPicker", "timeLapse"],
            states: ["keepAwake": .active, "colorPicker": .active, "timeLapse": .active])
        let layout = SurfaceLayout(tiles: [.init(.actions), .init(.desk), .init(.media)])
        #expect(
            availability.queryIDs(layout, target: .home, visible: true)
                == ["keepAwake", "colorPicker", "timeLapse"])
        #expect(availability.queryIDs(layout, target: .home, visible: false).isEmpty)
        #expect(availability.queryIDs(layout, target: .notch, visible: true).isEmpty)
    }

    @Test func removedAndDisabledCardsKeepTheirCoordinatesAndFilters() throws {
        var tile = SurfaceTile(.music)
        tile.column = 4
        tile.row = 12
        tile.height = 250
        tile.title = "My music"
        tile.hiddenFields = ["queue", "artist"]
        tile.sourceIDs = ["synthetic-player"]
        tile.contentKinds = ["future-content-kind"]
        tile.locked = true
        let saved = SurfaceLayout(tiles: [tile]).normalized()
        let disabled = try fixture(installed: ["music"], states: ["music": .disabled])
        #expect(disabled.projected(saved, target: .home).tiles.isEmpty)
        let removed = try fixture()
        #expect(removed.projected(saved, target: .home).tiles.isEmpty)
        let enabled = try fixture(installed: ["music"], states: ["music": .active])
        #expect(enabled.projected(saved, target: .home).tiles == saved.tiles)
        #expect(saved.tiles.first?.contentKinds == ["future-content-kind"])
    }

    @Test func runtimeProjectionKeepsNormalizationLimitsAndUniqueInstances() throws {
        var tile = SurfaceTile(.music)
        tile.span = 900
        tile.height = 12_000
        tile.title = String(repeating: "x", count: 200)
        let layout = SurfaceLayout(tiles: Array(repeating: tile, count: 300))
        let availability = try fixture(installed: ["music"], states: ["music": .active])
        let projected = availability.projected(layout, target: .home)
        #expect(projected == layout.normalized())
        #expect(projected.tiles.count == 1)
        #expect(projected.tiles.first?.span == 24)
        #expect(projected.tiles.first?.height == 1200)
        #expect(projected.tiles.first?.title.count == 64)
    }

    @Test func hiddenWidgetsMakeNoQueriesEvenWhenEnabled() throws {
        var tile = SurfaceTile(.music)
        tile.hidden = true
        let availability = try fixture(installed: ["music"], states: ["music": .active])
        #expect(
            availability.queryIDs(.init(tiles: [tile]), target: .home, visible: true).isEmpty)
    }

    @Test func allTransitionsRemoveCardsUntilTheWorkerIsReadyAgain() throws {
        for state in [HostActivationState.disabled, .starting, .stopping, .failed] {
            let availability = try fixture(installed: ["calendar"], states: ["calendar": state])
            #expect(
                availability.projected(.init(tiles: [.init(.calendar)]), target: .home).tiles
                    .isEmpty)
        }
        let restored = try fixture(installed: ["calendar"], states: ["calendar": .active])
        #expect(
            restored.projected(.init(tiles: [.init(.calendar)]), target: .home).tiles.count == 1)
    }

    @Test func notchTabsNeedTheirOwnProviderAndRetainUserOrdering() {
        var layout = SurfaceLayout.standard(.notch)
        layout.tabOrder = ["camera", "audio", "home", "clipboard", "agents", "files", "browser"]
        layout.hiddenTabs = ["files"]
        let active: Set<String> = ["notchShelf", "clipboard", "audioMixer", "herdr"]
        #expect(
            SurfaceNotchTab.visible(layout: layout, activeIDs: active)
                == [.camera, .audio, .home, .clipboard, .agents])
        #expect(
            SurfaceNotchTab.validSelection(.camera, visible: [.home, .audio]) == .home)
    }

    @Test func notchBrowserAndCameraPreviewBelongToTheNotchPackage() {
        let layout = SurfaceLayout.standard(.notch)
        #expect(
            SurfaceNotchTab.visible(layout: layout, activeIDs: ["notchShelf"])
                == [.home, .files, .camera])
        #expect(
            SurfaceNotchTab.visible(
                layout: layout, activeIDs: ["notchShelf"], browserEnabled: true)
                == [.home, .browser, .files, .camera])
    }

    @Test func glanceSettingsSurviveMissingProvidersWithoutRequestingTheirData() throws {
        let availability = try fixture(installed: ["calendar"], states: ["calendar": .active])
        #expect(availability.effectiveGlance(.nextMeeting) == .nextMeeting)
        #expect(availability.effectiveGlance(.permissions) == .none)
        #expect(availability.effectiveGlance(.limits) == .none)
        #expect(availability.effectiveGlance(.automatic) == .automatic)
    }

    @Test func unknownDownloadedWidgetDoesNotEraseTheRestOfTheLayout() throws {
        let unknown = try #require(SurfaceWidget(rawValue: "extension:futureExtension"))
        let layout = SurfaceLayout(tiles: [.init(.clocks), .init(unknown), .init(.music)])
        let decoded = SurfaceLayout.decode(layout.encoded, target: .home)
        #expect(decoded.tiles.map(\.widget) == [.clocks, unknown, .music])
        #expect(try fixture().status(unknown) == .unavailable)
        for raw in ["extension:", "extension:../bad", "extension:a/b", "extension:a.b"] {
            #expect(SurfaceWidget(rawValue: raw) == nil)
        }
    }

    private func fixture(
        installed: Set<String> = [], downloaded: Set<String> = [],
        states: [String: HostActivationState] = [:]
    ) throws -> HostSurfaceAvailability {
        HostSurfaceAvailability(
            knownIDs: Set(try HostIndex.bundled().map(\.id)), installedIDs: installed,
            downloadedIDs: downloaded.union(installed), states: states)
    }
}

@Suite @MainActor struct SurfaceLayoutPersistenceTests {
    @Test func profilesAndUndoRetainCompleteLayoutAcrossHostRelaunch() throws {
        let suite = "com.pulkit.edith.tests.surface-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SurfaceLayoutStore(defaults: defaults)
        store.update(.notch) {
            $0 = SurfacePreset.agents.layout(for: .notch)
            $0.notchAgentSources = ["synthetic-agent"]
            $0.notchExpandPermissions = true
            $0.hiddenTabs = ["files", "camera"]
        }
        let saved = store.notch
        #expect(store.saveProfile("My workspace", target: .notch))
        store.update(.notch) { $0.notchWidth = 800 }
        store.undo(.notch)
        #expect(store.notch == saved)
        store.redo(.notch)
        #expect(store.notch.notchWidth == 800)
        let restored = SurfaceLayoutStore(defaults: defaults)
        #expect(restored.notch == store.notch)
        let profile = try #require(restored.profiles(.notch).first)
        restored.applyProfile(profile.id)
        #expect(restored.notch == saved)
        restored.removeProfile(profile.id)
        #expect(restored.profiles(.notch).isEmpty)
        #expect(restored.restoreProfile(.notch))
        #expect(restored.profiles(.notch).first?.layout == saved)
    }

    @Test func homeAndNotchChangesAreIndependentAndNotifyOnlyOnEdits() throws {
        let suite = "com.pulkit.edith.tests.surface-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changes = 0
        let store = SurfaceLayoutStore(defaults: defaults) { changes += 1 }
        let notch = store.notch
        store.update(.home) { _ in }
        #expect(changes == 0)
        store.update(.home) { _ = $0.add(.ability("calendar"), column: 4, row: 10) }
        #expect(changes == 1)
        #expect(store.notch == notch)
        #expect(store.home.tiles.first?.widget == .ability("calendar"))
    }
}
