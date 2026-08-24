import EdithKit
import Foundation
import Testing
@testable import EdithHelper

@MainActor @Suite struct AppServicesTests {
    private let probe = "tabEnabledProbeKey"

    @Test func extensionDefaultsToDisabledWhenUnset() {
        SharedDefaults.store.removeObject(forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.extensionEnabled(probe))
    }

    @Test func extensionRespectsExplicitDisable() {
        SharedDefaults.store.set(false, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.extensionEnabled(probe))
    }

    @Test func extensionRespectsExplicitEnable() {
        SharedDefaults.store.set(true, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.extensionEnabled(probe))
    }

    @Test func preferenceDefaultsToEnabledWhenUnset() {
        SharedDefaults.store.removeObject(forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.preferenceOnByDefault(probe))
    }

    @Test func preferenceRespectsExplicitDisable() {
        SharedDefaults.store.set(false, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.preferenceOnByDefault(probe))
    }

    @Test func preferenceRespectsExplicitEnable() {
        SharedDefaults.store.set(true, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.preferenceOnByDefault(probe))
    }

    @Test func attentionRuntimeRequiresTheExtensionAndATrackingSource() {
        #expect(
            !AppServices.attentionEnabled(
                extensionEnabled: false,
                settings: AttentionSettings(isEnabled: true, trackingEnabled: true)))
        #expect(
            !AppServices.attentionEnabled(
                extensionEnabled: true, settings: AttentionSettings(isEnabled: true)))
        #expect(
            AppServices.attentionEnabled(
                extensionEnabled: true,
                settings: AttentionSettings(isEnabled: true, trackingEnabled: true)))
        #expect(
            AppServices.attentionEnabled(
                extensionEnabled: true,
                settings: AttentionSettings(isEnabled: true, browserTrackingEnabled: true)))
    }
}
