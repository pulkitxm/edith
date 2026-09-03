import Carbon.HIToolbox
import EdithCore
import Foundation
import Testing

@testable import EdithKit

@Suite struct HotKeyCatalogTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "HotKeyCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func everyGlobalHotKeyIsDeclaredOnce() {
        let ids = HotKeyCatalog.bindings.map(\.id)
        let carbonIDs = HotKeyCatalog.bindings.map(\.carbonID)
        #expect(Set(ids).count == ids.count)
        #expect(Set(carbonIDs).count == carbonIDs.count)
        #expect(ids.count == 8)
    }

    @Test func everyBindingNamesItsOwnDefaultsKeys() {
        let keys = HotKeyCatalog.bindings.flatMap { [$0.codeKey, $0.modsKey, $0.labelKey] }
        #expect(Set(keys).count == keys.count)
    }

    @Test func everyBindingButThePanelBelongsToARegisteredAbility() {
        for binding in HotKeyCatalog.bindings {
            guard let abilityID = binding.abilityID else {
                #expect(binding.id == HotKeyCatalog.panel)
                continue
            }
            #expect(
                ExtensionRegistry.entry(abilityID) != nil,
                "\(binding.id) points at \(abilityID), which is not an ability")
        }
    }

    @Test func aBindingFallsBackToItsDefaultUntilItIsSaved() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let binding = HotKeyCatalog.binding(HotKeyCatalog.panel)!

        #expect(binding.code(in: defaults) == kVK_ANSI_E)
        #expect(binding.mods(in: defaults) == cmdKey | optionKey)
        #expect(binding.label(in: defaults) == "⌥⌘E")

        binding.save(code: kVK_ANSI_J, mods: cmdKey, label: "⌘J", in: defaults)

        #expect(binding.code(in: defaults) == kVK_ANSI_J)
        #expect(binding.mods(in: defaults) == cmdKey)
        #expect(binding.label(in: defaults) == "⌘J")
    }

    @Test func aBindingIsOffWhileItsAbilityIsOff() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clipboard = HotKeyCatalog.binding(HotKeyCatalog.clipboard)!

        #expect(!clipboard.isEnabled(in: defaults))

        defaults.set(true, forKey: AppStorageKeys.Suites.desk)
        defaults.set(true, forKey: AppStorageKeys.Clipboard.enabled)

        #expect(clipboard.isEnabled(in: defaults))
    }

    @Test func thePanelHotKeyIsAlwaysAvailable() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HotKeyCatalog.binding(HotKeyCatalog.panel)?.isEnabled(in: defaults) == true)
        #expect(HotKeyCatalog.enabled(in: defaults).map(\.id) == [HotKeyCatalog.panel])
    }

    @Test func theShippedDefaultsDoNotCollide() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for key in [
            AppStorageKeys.Suites.desk, AppStorageKeys.Suites.system,
            AppStorageKeys.Suites.media,
        ] {
            defaults.set(true, forKey: key)
        }
        for binding in HotKeyCatalog.bindings {
            if let abilityID = binding.abilityID,
                let entry = ExtensionRegistry.entry(abilityID)
            {
                defaults.set(true, forKey: entry.defaultsKey)
            }
        }

        #expect(HotKeyCatalog.conflicts(in: defaults).isEmpty)
    }

    @Test func twoBindingsOnOneCombinationAreReportedTogether() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AppStorageKeys.Suites.desk)
        defaults.set(true, forKey: AppStorageKeys.Clipboard.enabled)
        let panel = HotKeyCatalog.binding(HotKeyCatalog.panel)!
        let clipboard = HotKeyCatalog.binding(HotKeyCatalog.clipboard)!
        clipboard.save(
            code: panel.code(in: defaults), mods: panel.mods(in: defaults), label: "clash",
            in: defaults)

        let conflicts = HotKeyCatalog.conflicts(in: defaults)

        #expect(conflicts.count == 1)
        #expect(conflicts.first?.map(\.id) == ["clipboard", "panel"])
    }
}
