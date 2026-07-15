import Testing

@testable import EdithKit

@Suite struct FeatureGatesTests {
    @Test func presenterInactiveWhenExtensionDisabled() {
        #expect(!FeatureGates.presenterActive(enabled: false, manual: true, autoActive: true))
        #expect(!FeatureGates.presenterActive(enabled: false, manual: true, autoActive: false))
        #expect(!FeatureGates.presenterActive(enabled: false, manual: false, autoActive: true))
    }

    @Test func presenterActiveFromManualOrAuto() {
        #expect(FeatureGates.presenterActive(enabled: true, manual: true, autoActive: false))
        #expect(FeatureGates.presenterActive(enabled: true, manual: false, autoActive: true))
        #expect(!FeatureGates.presenterActive(enabled: true, manual: false, autoActive: false))
    }

    @Test func detectorNeedsBothMasterAndAutoToggles() {
        #expect(FeatureGates.presenterDetectorWanted(presenterEnabled: true, autoEnabled: true))
        #expect(!FeatureGates.presenterDetectorWanted(presenterEnabled: true, autoEnabled: false))
        #expect(!FeatureGates.presenterDetectorWanted(presenterEnabled: false, autoEnabled: true))
    }

    @Test func preventSleepClearsWhenSystemDisabled() {
        #expect(!FeatureGates.preventSleepPersisted(systemOn: false, current: true))
        #expect(FeatureGates.preventSleepPersisted(systemOn: true, current: true))
        #expect(!FeatureGates.preventSleepPersisted(systemOn: true, current: false))
    }

    @Test func lastUsageProviderTurnsOffDependentFeatures() {
        let state = AgentUsageSettingsState(
            enabled: true, claudeEnabled: false, codexEnabled: false, menuBarEnabled: true,
            alertsEnabled: true, selectedProvider: .codex)
        let next = AgentUsageSettingsFlow.providersChanged(state)
        #expect(!next.enabled)
        #expect(!next.menuBarEnabled)
        #expect(!next.alertsEnabled)
    }

    @Test func remainingUsageProviderKeepsDependentFeatures() {
        let state = AgentUsageSettingsState(
            enabled: true, claudeEnabled: false, codexEnabled: true, menuBarEnabled: true,
            alertsEnabled: true, selectedProvider: .codex)
        #expect(AgentUsageSettingsFlow.providersChanged(state) == state)
    }

    @Test func reenablingUsageRestoresSelectedProvider() {
        let state = AgentUsageSettingsState(
            enabled: false, claudeEnabled: false, codexEnabled: false, menuBarEnabled: false,
            alertsEnabled: false, selectedProvider: .codex)
        let next = AgentUsageSettingsFlow.setEnabled(true, in: state)
        #expect(next.enabled)
        #expect(!next.claudeEnabled)
        #expect(next.codexEnabled)
        #expect(!next.menuBarEnabled)
        #expect(!next.alertsEnabled)
    }
}
