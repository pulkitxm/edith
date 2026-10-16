import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

@Suite(.serialized) @MainActor struct HerdrNotchAgentsCardTests {
    @Test func cardLaysOutWithEmptyActivity() throws {
        let suite = "notch-agents-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = AgentActivityMonitor(defaults: defaults)
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        let host = NSHostingView(rootView: HerdrNotchAgentsCard(store: store, monitor: monitor))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}
