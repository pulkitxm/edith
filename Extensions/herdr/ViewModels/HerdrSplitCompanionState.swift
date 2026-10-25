import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class HerdrSplitCompanionState {
    private(set) var companion: HerdrSplitCompanion

    private let agentID: String
    private let defaults: UserDefaults

    init(agentID: String, defaults: UserDefaults = SharedDefaults.store) {
        self.agentID = agentID
        self.defaults = defaults
        companion = HerdrSplitCompanions.companion(for: agentID, defaults)
    }

    func select(_ companion: HerdrSplitCompanion) {
        guard companion != self.companion else { return }
        self.companion = companion
        HerdrSplitCompanions.set(companion, for: agentID, defaults)
    }

    func follow(_ view: HerdrAgentView) {
        if let companion = view.companion { select(companion) }
    }
}
