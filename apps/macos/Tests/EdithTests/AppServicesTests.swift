import Foundation
import Testing
@testable import Edith

@MainActor @Suite struct AppServicesTests {
    private let probe = "tabEnabledProbeKey"

    @Test func defaultsToEnabledWhenUnset() {
        UserDefaults.standard.removeObject(forKey: probe)
        #expect(AppServices.tabEnabled(probe))
    }

    @Test func respectsExplicitDisable() {
        UserDefaults.standard.set(false, forKey: probe)
        defer { UserDefaults.standard.removeObject(forKey: probe) }
        #expect(!AppServices.tabEnabled(probe))
    }

    @Test func respectsExplicitEnable() {
        UserDefaults.standard.set(true, forKey: probe)
        defer { UserDefaults.standard.removeObject(forKey: probe) }
        #expect(AppServices.tabEnabled(probe))
    }
}
