import EdithKit
import Foundation
import Testing
@testable import EdithHelper

@MainActor @Suite struct AppServicesTests {
    private let probe = "tabEnabledProbeKey"

    @Test func constructionDoesNotEagerlyStartExtensionServices() {
        let services = AppServices()

        #expect(services.usage == nil)
        #expect(services.music == nil)
        #expect(services.system == nil)
        #expect(services.machines == nil)
        #expect(services.calendar == nil)
        #expect(services.notchShelf == nil)
        #expect(services.colorPicker == nil)
        #expect(services.clipboard == nil)
        #expect(services.focusDim == nil)
        #expect(services.presenter == nil)
        #expect(services.micMute == nil)
        #expect(services.lidAwake == nil)
        #expect(services.systemStats == nil)
        #expect(services.attention == nil)
    }

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
