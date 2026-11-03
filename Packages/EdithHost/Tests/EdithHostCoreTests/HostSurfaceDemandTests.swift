import EdithExtensionSupport
import Testing

@testable import EdithHostCore

@Suite struct HostSurfaceDemandTests {
    @Test func visibleCardsAndNotchTabsDemandTheirDeclaredProviders() throws {
        let entries = try HostIndex.bundled()
        var hidden = SurfaceTile(.ability("hinge"))
        hidden.hidden = true
        let home = SurfaceLayout(tiles: [SurfaceTile(.ability("emoji")), hidden])
        var notch = SurfaceLayout(tiles: [SurfaceTile(.music)])
        notch.hiddenTabs = ["audio"]
        let closed = HostSurfaceDemand.providerIDs(
            home: home, notch: notch, notchEnabled: false, entries: entries)
        #expect(closed == ["emoji"])
        let open = HostSurfaceDemand.providerIDs(
            home: home, notch: notch, notchEnabled: true, entries: entries)
        #expect(open == ["emoji", "music", "clipboard", "notchShelf"])
    }

    @Test func homeNotchAndTabDeclarationsAreIndependent() {
        let entries = [
            entry("home", home: ["music"]),
            entry("notch", notch: ["music"]),
            entry("tab", tabs: ["audio"]),
            entry("undeclared"),
        ]
        let music = SurfaceLayout(tiles: [SurfaceTile(.music)])
        var hiddenTabs = music
        hiddenTabs.hiddenTabs = SurfaceNotchTab.allCases.map(\.rawValue)
        #expect(
            HostSurfaceDemand.providerIDs(
                home: music, notch: music, notchEnabled: false, entries: entries) == ["home"])
        #expect(
            HostSurfaceDemand.providerIDs(
                home: music, notch: hiddenTabs, notchEnabled: true, entries: entries)
                == ["home", "notch"])
        #expect(
            HostSurfaceDemand.providerIDs(
                home: music, notch: music, notchEnabled: true, entries: entries)
                == ["home", "notch", "tab"])
    }

    @Test func bundledDeclarationsPreserveEveryExistingCardAndTabProvider() throws {
        let entries = try HostIndex.bundled()
        for widget in SurfaceWidget.allCases + entries.map({ .ability($0.id) }) {
            for target in SurfaceTarget.allCases {
                let providers = Set(
                    entries.filter {
                        (target == .home ? $0.homeCards : $0.notchCards).contains(widget.rawValue)
                    }.map(\.id))
                #expect(providers == widget.providerIDs)
            }
        }
        for tab in SurfaceNotchTab.allCases {
            let providers = Set(entries.filter { $0.notchTabs.contains(tab.rawValue) }.map(\.id))
            #expect(providers == tab.providerIDs)
        }
    }

    private func entry(
        _ id: String, home: [String] = [], notch: [String] = [], tabs: [String] = []
    ) -> HostExtension {
        HostExtension(
            id: id, title: id, symbolName: "square", category: "desk", background: false,
            homeCards: home, notchCards: notch, notchTabs: tabs)
    }
}
