import Foundation
import Testing

@testable import EdithKit

@Suite struct SharedDefaultsTests {
    private func suite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func copiesUnmigratedKeysOnce() {
        let from = suite("edith-tests-from-\(UUID().uuidString)")
        let to = suite("edith-tests-to-\(UUID().uuidString)")
        from.set("bar", forKey: "foo")

        SharedDefaults.migrate(from: from, to: to, flagKey: "migrated")

        #expect(to.string(forKey: "foo") == "bar")
        #expect(to.bool(forKey: "migrated"))
    }

    @Test func neverOverwritesExistingDestinationValue() {
        let from = suite("edith-tests-from-\(UUID().uuidString)")
        let to = suite("edith-tests-to-\(UUID().uuidString)")
        from.set("fromValue", forKey: "foo")
        to.set("toValue", forKey: "foo")

        SharedDefaults.migrate(from: from, to: to, flagKey: "migrated")

        #expect(to.string(forKey: "foo") == "toValue")
    }

    @Test func skipsSystemPrefixedKeys() {
        let from = suite("edith-tests-from-\(UUID().uuidString)")
        let to = suite("edith-tests-to-\(UUID().uuidString)")
        from.set(true, forKey: "NSStatusItem Visible foo")
        let appleLanguagesBefore = to.object(forKey: "AppleLanguages") as? NSObject
        from.set(["xx"], forKey: "AppleLanguages")

        SharedDefaults.migrate(from: from, to: to, flagKey: "migrated")

        #expect(to.object(forKey: "NSStatusItem Visible foo") == nil)
        #expect(to.object(forKey: "AppleLanguages") as? NSObject == appleLanguagesBefore)
    }

    @Test func runsOnlyOnce() {
        let from = suite("edith-tests-from-\(UUID().uuidString)")
        let to = suite("edith-tests-to-\(UUID().uuidString)")
        from.set("first", forKey: "foo")
        SharedDefaults.migrate(from: from, to: to, flagKey: "migrated")

        from.set("second", forKey: "foo")
        SharedDefaults.migrate(from: from, to: to, flagKey: "migrated")

        #expect(to.string(forKey: "foo") == "first")
    }
}
