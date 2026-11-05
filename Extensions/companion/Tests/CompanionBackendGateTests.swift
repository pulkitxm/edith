import Testing

@testable import CompanionExtension

@Suite struct CompanionBackendGateTests {
    @Test func nothingBlocksBeforeTheFirstCheck() {
        #expect(
            CompanionBackendGate.resolve(
                tab: .chat, checked: false, reachable: false, hasDeployment: false) == .proceed)
    }

    @Test func aReachableBackendProceeds() {
        #expect(
            CompanionBackendGate.resolve(
                tab: .chat, checked: true, reachable: true, hasDeployment: true) == .proceed)
    }

    @Test func noDeploymentAndNoBackendAsksForSetup() {
        #expect(
            CompanionBackendGate.resolve(
                tab: .library, checked: true, reachable: false, hasDeployment: false) == .notSetUp)
    }

    @Test func aDeploymentThatIsDownSaysItIsNotRunning() {
        #expect(
            CompanionBackendGate.resolve(
                tab: .mind, checked: true, reachable: false, hasDeployment: true) == .notRunning)
    }

    @Test func backendAndSettingsStayUsableWhileDown() {
        for tab in [CompanionTab.setup, .settings] {
            #expect(
                CompanionBackendGate.resolve(
                    tab: tab, checked: true, reachable: false, hasDeployment: false) == .proceed)
        }
    }

    @Test func zeroEpisodesAndChunksMeansAnEmptyMemory() {
        let empty = CompanionStatus(
            sources: 0, episodes: 0, claims: 0, observations: 0, chunks: 0, pendingEpisodes: 0,
            latestIngestedAt: nil)
        let used = CompanionStatus(
            sources: 1, episodes: 3, claims: 0, observations: 0, chunks: 9, pendingEpisodes: 0,
            latestIngestedAt: nil)
        #expect(CompanionMemoryState.resolve(status: empty) == .empty)
        #expect(CompanionMemoryState.resolve(status: used) == .populated)
        #expect(CompanionMemoryState.resolve(status: nil) == .populated)
    }

    @Test func theHeaderSummarySkipsEmptyMemoryAndUsesPlainWords() {
        let status = { (episodes: Int, observations: Int) in
            CompanionStatus(
                sources: 1, episodes: episodes, claims: 0, observations: observations,
                chunks: episodes * 4, pendingEpisodes: 0, latestIngestedAt: nil)
        }
        #expect(CompanionMemoryState.summary(status: nil) == nil)
        #expect(CompanionMemoryState.summary(status: status(0, 0)) == nil)
        #expect(CompanionMemoryState.summary(status: status(1, 0)) == "1 item saved")
        #expect(
            CompanionMemoryState.summary(status: status(12, 40))
                == "12 items saved, 40 observations")
    }
}
