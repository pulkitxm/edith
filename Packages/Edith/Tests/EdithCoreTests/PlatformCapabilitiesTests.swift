import Testing

@testable import EdithCore

@Suite struct PlatformCapabilitiesTests {
    @Test func macOSSupportsEveryDeclaredCapability() {
        for capability in PlatformCapability.allCases {
            #expect(PlatformCapabilities.macOS.state(for: capability).isSupported)
        }
    }

    @Test func missingOptionalCapabilitiesDegradeAnExtension() {
        let capabilities = PlatformCapabilities(
            states: [
                .clipboardHistory: .available,
                .globalPaste: .unsupported("Unavailable"),
            ])
        let availability = capabilities.availability(
            required: [.clipboardHistory], optional: [.globalPaste])

        #expect(availability == .degraded([.globalPaste]))
    }
}
