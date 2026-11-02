import EdithExtensionSupport
import Testing

@testable import EdithHostCore

@Suite struct HostSurfaceDemandTests {
    @Test func visibleCardsAndNotchTabsDemandTheirProviders() {
        var hidden = SurfaceTile(.ability("hinge"))
        hidden.hidden = true
        let home = SurfaceLayout(tiles: [SurfaceTile(.ability("emoji")), hidden])
        var notch = SurfaceLayout(tiles: [SurfaceTile(.music)])
        notch.hiddenTabs = ["audio"]
        let closed = HostSurfaceDemand.providerIDs(home: home, notch: notch, notchEnabled: false)
        #expect(closed == ["emoji"])
        let open = HostSurfaceDemand.providerIDs(home: home, notch: notch, notchEnabled: true)
        #expect(open.isSuperset(of: ["emoji", "music", "clipboard", "notchShelf"]))
        #expect(!open.contains("hinge"))
        #expect(!open.contains("audioMixer"))
    }
}
