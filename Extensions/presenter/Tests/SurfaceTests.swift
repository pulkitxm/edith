import EdithExtensionSupport
import Testing

@testable import PresenterExtension

struct PresenterSurfaceTests {
    @Test func automaticPresentingDoesNotLightTheManualTile() throws {
        let snapshot = PresenterSurface.snapshot(
            .init(
                enabled: true, manual: false, autoActive: true, autoReason: "Synthetic share",
                active: true))
        #expect(snapshot.actions.first?.id == "start")
        #expect(snapshot.actions.first?.title == "Turn on")
        #expect(snapshot.metrics.first?.value == "Off")
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "presenter")
    }

    @Test func manualModeOffersTheStopAction() throws {
        let snapshot = PresenterSurface.snapshot(
            .init(enabled: true, manual: true, autoActive: false, autoReason: nil, active: true))
        #expect(snapshot.actions.first?.id == "stop")
        #expect(snapshot.metrics.first?.value == "On")
    }
}
