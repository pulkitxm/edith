import Testing
@testable import EdithHostCore

@MainActor @Suite struct HostCLIGatewayStateTests {
    @Test func installedExtensionThatNeverRanIsDisabledNotNotInstalled() {
        #expect(HostCLIGateway.stateName(nil, installed: true) == "disabled")
    }
    @Test func missingExtensionIsNotInstalled() {
        #expect(HostCLIGateway.stateName(nil, installed: false) == "notInstalled")
    }
    @Test func sessionStateWinsOverInstalledFlag() {
        #expect(HostCLIGateway.stateName(.active, installed: true) == "active")
        #expect(HostCLIGateway.stateName(.failed, installed: true) == "failed")
    }
}
