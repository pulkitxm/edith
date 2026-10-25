import Carbon.HIToolbox
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostPanelServicesTests {
    @Test func panelBindingPreservesDefaultAndOwnedPreference() throws {
        let name = "com.pulkit.edith.tests.panel-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = try HostPanelService.binding(defaults: defaults)
        #expect(initial.code == UInt32(kVK_ANSI_E))
        #expect(initial.modifiers == UInt32(optionKey | cmdKey))
        defaults.set(kVK_ANSI_A, forKey: AppStorageKeys.General.hotKeyCode)
        defaults.set(controlKey | shiftKey, forKey: AppStorageKeys.General.hotKeyMods)
        let selected = try HostPanelService.binding(defaults: defaults)
        #expect(selected.code == UInt32(kVK_ANSI_A))
        #expect(selected.modifiers == UInt32(controlKey | shiftKey))
    }

    @Test func malformedPanelBindingsCannotRegisterForeignKeyBits() throws {
        let name = "com.pulkit.edith.tests.panel-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for code in [-1, 128, Int.max] {
            defaults.set(code, forKey: AppStorageKeys.General.hotKeyCode)
            #expect(throws: CocoaError.self) { try HostPanelService.binding(defaults: defaults) }
        }
        defaults.set(kVK_ANSI_E, forKey: AppStorageKeys.General.hotKeyCode)
        for modifiers in [-1, 1, Int.max] {
            defaults.set(modifiers, forKey: AppStorageKeys.General.hotKeyMods)
            #expect(throws: CocoaError.self) { try HostPanelService.binding(defaults: defaults) }
        }
    }
}
