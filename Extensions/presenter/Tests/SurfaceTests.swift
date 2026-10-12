import EdithExtensionSupport
import Testing
@testable import PresenterExtension

struct PresenterSurfaceTests {
    @Test func AutomaticPresentingOffersTheStopAction() throws {
        let snapshot = PresenterSurface.snapshot(
            .init(
                enabled: true, manual: false, autoActive: true, autoReason: "Synthetic share",
                active: true))
        #expect(snapshot.actions.first?.id == "stop")
        #expect(snapshot.rows.first?.value == "Presenting")
        #expect(snapshot.rows.first?.detail == "Synthetic share")
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "presenter")
    }
}
