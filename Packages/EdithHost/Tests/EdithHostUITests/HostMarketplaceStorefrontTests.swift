import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

struct HostMarketplaceStorefrontTests {
    private func entry(
        _ id: String, title: String? = nil, category: String = "desk", tagline: String? = nil,
        summary: String = ""
    ) -> HostExtension {
        HostExtension(
            id: id, title: title ?? id.capitalized, icon: .heart, category: category,
            guide: tagline.map { HostExtensionGuide(tagline: $0, summary: summary, steps: []) })
    }

    @Test func searchMatchesTitleTaglineAndSummary() {
        let entries = [
            entry("clipboard", title: "Clipboard", tagline: "History with instant paste"),
            entry(
                "emoji", title: "Emoji", tagline: "Type any emoji",
                summary: "Works from the keyboard"),
            entry("hinge", title: "Hinge", tagline: "Fold the desktop away"),
        ]
        func ids(_ query: String) -> [String] {
            HostMarketplaceCatalog.filter(entries, query: query, category: "all").map(\.id)
        }
        #expect(ids("clip") == ["clipboard"])
        #expect(ids("  PASTE ") == ["clipboard"])
        #expect(ids("keyboard") == ["emoji"])
        #expect(ids("fold") == ["hinge"])
        #expect(ids("zzz").isEmpty)
        #expect(ids("") == ["clipboard", "emoji", "hinge"])
    }

    @Test func missingGuideFallsBackToTheCategoryTitle() {
        #expect(HostMarketplaceCatalog.tagline(entry("a", category: "media")) == "Part of Media")
        #expect(HostMarketplaceCatalog.tagline(entry("b", tagline: "Does b")) == "Does b")
    }

    @Test func labsStayHiddenUntilSearchedOrScoped() {
        let entries = [entry("a"), entry("toy", category: "labs", tagline: "Toy")]
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "", category: "all").map(\.id) == ["a"])
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "toy", category: "all").map(\.id) == [
                "toy"
            ])
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "", category: "labs").map(\.id) == ["toy"]
        )
        #expect(
            HostMarketplaceCatalog.filter(
                entries, query: "", category: "all", scope: .installed, installed: ["toy"]
            ).map(\.id) == ["toy"])
    }

    @Test func searchingLooksAcrossEveryCategory() {
        let entries = [
            entry("a", category: "media", tagline: "Alpha"), entry("b", tagline: "Beta"),
        ]
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "beta", category: "media").map(\.id) == [
                "b"
            ])
        #expect(
            HostMarketplaceCatalog.filter(entries, query: "", category: "media").map(\.id) == ["a"])
    }

    @Test func scopesNarrowToInstalledAndUpdatable() {
        let entries = [entry("a"), entry("b"), entry("c")]
        func ids(_ scope: HostMarketplaceScope) -> [String] {
            HostMarketplaceCatalog.filter(
                entries, query: "", category: "all", scope: scope, installed: ["a", "b"],
                updatable: ["b"]
            ).map(\.id)
        }
        #expect(ids(.all) == ["a", "b", "c"])
        #expect(ids(.installed) == ["a", "b"])
        #expect(ids(.updates) == ["b"])
    }

    @Test func featuredSkipsInstalledAndRespectsTheLimit() {
        let entries = HostMarketplaceCatalog.featuredIDs.map { entry($0) }
        let all = HostMarketplaceCatalog.featured(entries, installed: [])
        #expect(all.map(\.id) == Array(HostMarketplaceCatalog.featuredIDs.prefix(4)))
        let skipped = HostMarketplaceCatalog.featured(
            entries, installed: [HostMarketplaceCatalog.featuredIDs[0]])
        #expect(skipped.count == 4)
        #expect(!skipped.map(\.id).contains(HostMarketplaceCatalog.featuredIDs[0]))
    }

    @Test func groupsFollowSuiteOrderAndDropEmptySuites() {
        let groups = HostMarketplaceCatalog.groups([
            entry("m", category: "media"), entry("a", category: "agents"),
        ])
        #expect(groups.map(\.suite.id) == ["agents", "media"])
    }

    @Test(
        arguments: [
            (
                false, false, nil, false, false, true, false, false, false, false,
                HostExtensionRowState.Stage.notInstalled
            ),
            (false, false, nil, false, false, true, false, true, false, false, .failed),
            (false, false, nil, false, false, false, false, false, false, false, .unavailable),
            (false, false, nil, false, true, true, false, false, false, false, .updateAvailable),
            (false, false, nil, false, true, false, false, false, false, false, .unavailable),
            (false, false, nil, false, false, true, true, false, false, false, .installed),
            (false, false, nil, false, false, true, true, false, true, false, .installed),
            (false, false, nil, false, false, true, true, false, true, true, .ready),
            (false, false, nil, false, false, true, true, true, true, true, .updateAvailable),
            (false, false, nil, true, false, true, true, false, true, true, .starting),
            (true, false, nil, false, false, true, true, false, true, true, .pending),
            (false, true, nil, false, false, true, true, false, true, true, .pending),
        ]
            as [(
                Bool, Bool, HostExtensionOperation?, Bool, Bool, Bool, Bool, Bool, Bool, Bool,
                HostExtensionRowState.Stage
            )])
    func stageMapsMarketplaceFacts(
        removing: Bool, pendingDisable: Bool, operation: HostExtensionOperation?, starting: Bool,
        downloaded: Bool, available: Bool, installed: Bool, update: Bool, on: Bool, ready: Bool,
        expected: HostExtensionRowState.Stage
    ) {
        let failed = expected == .failed
        let stage = HostExtensionRowState.resolveStage(
            removing: removing, pendingDisable: pendingDisable, operation: operation,
            starting: starting, installed: installed, downloaded: downloaded, available: available,
            updateAvailable: update, failed: failed, on: on, ready: ready)
        #expect(stage == expected)
    }

    @Test func operationPhasesMapToProgressStages() {
        func stage(_ phase: HostExtensionOperation.Phase) -> HostExtensionRowState.Stage {
            HostExtensionRowState.resolveStage(
                removing: false, pendingDisable: false, operation: .init(phase: phase),
                starting: false, installed: false, downloaded: false, available: true,
                updateAvailable: false, failed: false, on: false, ready: false)
        }
        #expect(stage(.queued) == .downloading)
        #expect(stage(.downloading) == .downloading)
        #expect(stage(.installing) == .downloading)
        #expect(stage(.verifying) == .verifying)
        #expect(stage(.starting) == .starting)
        #expect(HostExtensionOperation(phase: .verifying).summary == "Verifying")
        #expect(HostExtensionOperation(phase: .starting).summary == "Starting")
    }

    @Test func actionTitlesAreGetOpenUpdateAndRetry() {
        #expect(HostExtensionRowState.Action.download.title == "Get")
        #expect(HostExtensionRowState.Action.open.title == "Open")
        #expect(HostExtensionRowState.Action.update.title == "Update")
        #expect(HostExtensionRowState.Action.retry.title == "Retry")
    }

    @Test func openTargetNamesThePageAndSection() {
        #expect(HostExtensionActions.openTarget(extensionID: "usage")?.page == "dashboard")
        #expect(HostExtensionActions.openTarget(extensionID: "usage")?.section == nil)
        let maintenance = HostExtensionActions.openTarget(extensionID: "homebrew")
        #expect(maintenance == .init(page: "appMaintenance", section: "Packages"))
        #expect(HostExtensionActions.openTarget(extensionID: "keepAwake") == nil)
    }

    @Test func placementsDescribeWhereAnExtensionLives() {
        let hotkey = HostHotKey(
            id: "mute", prefix: "mic", title: "Mute", subtitle: "", code: 46, modifiers: 0,
            label: "⇧⌘M")
        let tool = HostExtension(
            id: "tool", title: "Tool", icon: .heart, category: "desk", hotkeys: [hotkey],
            homeCards: ["a", "b"], notchCards: ["n"])
        let found = HostExtensionPlacements.placements(
            for: tool, route: ("dashboard", nil), pageTitles: ["dashboard": "Usage"])
        #expect(found.map(\.title) == ["Sidebar", "Home", "Notch", "Hotkeys"])
        #expect(found[0].detail.contains("Usage"))
        #expect(found[1].detail.contains("2 cards"))
        #expect(found[3].detail.contains("⇧⌘M Mute"))
        let maintenance = HostExtensionPlacements.placements(
            for: tool, route: ("appMaintenance", "Packages"),
            sectionTitles: ["Packages": "Packages"])
        #expect(maintenance[0].title == "Maintenance")
        #expect(maintenance[0].detail.contains("Packages"))
        let quiet = HostExtension(id: "quiet", title: "Quiet", icon: .heart, category: "desk")
        #expect(HostExtensionPlacements.placements(for: quiet).map(\.title) == ["Background"])
    }

    @Test func hintsPointAtTheFirstPlaceToLook() {
        let hotkey = HostHotKey(
            id: "k", prefix: "p", title: "Go", subtitle: "", code: 1, modifiers: 0, label: "⌥Space")
        let keyed = HostExtension(
            id: "k", title: "K", icon: .heart, category: "desk", hotkeys: [hotkey])
        #expect(HostExtensionPlacements.hint(for: keyed, route: nil) == "Press ⌥Space to use it.")
        #expect(
            HostExtensionPlacements.hint(
                for: keyed, route: ("music", nil), pageTitles: ["music": "Music"])
                == "Find it in the sidebar as Music.")
        #expect(
            HostExtensionPlacements.hint(for: keyed, route: ("appMaintenance", "Cleaner"))
                == "Find it in the sidebar under Maintenance.")
    }
}
