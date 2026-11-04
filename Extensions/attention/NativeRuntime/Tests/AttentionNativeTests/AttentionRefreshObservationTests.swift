import Foundation
import Observation
import Testing

@testable import AttentionNative

@Suite(.serialized) @MainActor struct AttentionRefreshObservationTests {
    @Test func refreshingUnchangedHistoryDoesNotInvalidateThePage() async throws {
        let fixture = try AttentionSyntheticHistory.make(days: 1, eventsPerDay: 40)
        defer { fixture.cleanup() }
        let model = AttentionPageModel(
            repository: fixture.repository,
            uiClient: fixture.client(counter: AttentionRequestCounter()))
        model.select(.today)
        model.reload()
        await model.waitForReload()
        await model.checkBrowser()
        var changed: [String] = []
        let probes: [(String, () -> Void)] = [
            ("hasStoredEvents", { _ = model.hasStoredEvents }),
            ("extensionInstalled", { _ = model.extensionInstalled }),
            ("browserConnected", { _ = model.browserConnected }),
            ("errorMessage", { _ = model.errorMessage }),
            ("loading.state", { _ = model.loading.state }),
            ("loading.hasContent", { _ = model.loading.hasContent }),
        ]
        for (name, read) in probes {
            withObservationTracking(read) { changed.append(name) }
        }
        model.reload()
        await model.waitForReload()
        await model.checkBrowser()
        #expect(changed.isEmpty, "\(changed)")
    }
}
