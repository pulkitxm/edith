import Testing

@testable import EdithCore

@Suite struct PlatformCapabilitiesTests {
    @Test func macOSSupportsEveryDeclaredCapability() {
        for capability in PlatformCapability.allCases {
            #expect(PlatformCapabilities.macOS.state(for: capability).isSupported)
        }
    }

    @Test func ubuntuDoesNotClaimUnimplementedCapabilities() {
        for capability in PlatformCapability.allCases {
            #expect(!PlatformCapabilities.ubuntu.state(for: capability).isSupported)
        }
    }

    @Test func ubuntuIdentifiesPlannedNativeIntegrations() {
        let plannedCapabilities: [PlatformCapability] = [
            .cameraPreview, .clipboardHistory, .globalPaste, .globalShortcuts, .inputSuppression,
            .notifications, .screenColorSampling, .screenShareDetection, .windowDimming,
        ]

        for capability in plannedCapabilities {
            guard case .integrationRequired = PlatformCapabilities.ubuntu.state(for: capability)
            else {
                Issue.record("Expected an Ubuntu integration for \(capability.rawValue)")
                continue
            }
        }
    }

    @Test func ubuntuBlocksExtensionsThatNeedShellIntegration() {
        let availability = PlatformCapabilities.ubuntu.availability(
            required: [.windowDimming], optional: [])

        #expect(availability == .unavailable([.windowDimming]))
    }

    @Test func missingOptionalCapabilitiesDegradeAnExtension() {
        let capabilities = PlatformCapabilities(
            platform: .linux,
            states: [
                .clipboardHistory: .available,
                .globalPaste: .integrationRequired("GNOME input integration"),
            ])
        let availability = capabilities.availability(
            required: [.clipboardHistory], optional: [.globalPaste])

        #expect(availability == .degraded([.globalPaste]))
    }
}
