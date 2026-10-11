import Testing

@testable import EdithHostCore

struct HostPresentationReadinessTests {
    @Test func onlyHealthyVisibleSettledConnectionsAreAdmitted() {
        for connected in [false, true] {
            for failed in [false, true] {
                for detached in [false, true] {
                    for attached in [false, true] {
                        for visible in [false, true] {
                            for updating in [false, true] {
                                let state = HostPresentationReadiness(
                                    connected: connected, failed: failed, detached: detached,
                                    attached: attached, visible: visible, updating: updating)
                                #expect(
                                    state.ready
                                        == (connected && !failed && !detached && attached && visible
                                            && !updating))
                            }
                        }
                    }
                }
            }
        }
    }
}
