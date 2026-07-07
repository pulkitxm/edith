import EdithKit
import Foundation
import Testing
@testable import EdithMenuBar

@MainActor @Suite struct AppServicesTests {
    private let probe = "tabEnabledProbeKey"

    @Test func defaultsToEnabledWhenUnset() {
        SharedDefaults.store.removeObject(forKey: probe)
        #expect(AppServices.tabEnabled(probe))
    }

    @Test func respectsExplicitDisable() {
        SharedDefaults.store.set(false, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(!AppServices.tabEnabled(probe))
    }

    @Test func respectsExplicitEnable() {
        SharedDefaults.store.set(true, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.tabEnabled(probe))
    }

    @Test func featureDefaultsToOffWhenUnset() {
        SharedDefaults.store.removeObject(forKey: probe)
        #expect(!AppServices.featureOffByDefault(probe))
    }

    @Test func featureRespectsExplicitEnable() {
        SharedDefaults.store.set(true, forKey: probe)
        defer { SharedDefaults.store.removeObject(forKey: probe) }
        #expect(AppServices.featureOffByDefault(probe))
    }
}
