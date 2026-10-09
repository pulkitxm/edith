import EdithExtensionSupport
import Foundation
import Testing
@testable import JevExtension

struct JevSurfaceTests {
    @Test func configurationDoesNotExposeSavedKeyInformation() throws {
        let snapshot = JevSurface.snapshot(
            .init(state: .ready, keyHint: "synthetic-secret", decisions: 8, medianMilliseconds: 25))
        #expect(snapshot.rows.first?.value == "Ready")
        #expect(snapshot.metrics.map(\.value) == ["8", "25 ms"])
        #expect(
            !String(decoding: try snapshot.encoded(), as: UTF8.self).contains("synthetic-secret"))
        #expect(snapshot.actions.isEmpty)
    }
}
