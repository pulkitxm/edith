import Carbon.HIToolbox
import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHost

@Suite(.serialized) @MainActor struct HostPanelServicesTests {
    @Test(arguments: [false, true])
    func nativeHotKeyHandlersRouteOwnedEventsAndPassForeignEvents(panelFirst: Bool) throws {
        _ = TestWindowHost.application
        let name = "com.pulkit.edith.tests.panel-chain-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(kVK_F19, forKey: AppStorageKeys.General.hotKeyCode)
        defaults.set(cmdKey | controlKey | optionKey, forKey: AppStorageKeys.General.hotKeyMods)
        var opened = 0
        var invoked = 0
        let panel = HostPanelService(defaults: defaults) { opened += 1 }
        let binding = ExtensionHotKeyBinding(
            id: name, carbonID: 91, prefix: name, defaultCode: kVK_F18,
            defaultModifiers: cmdKey | controlKey | optionKey)
        defer {
            panel.shutdown()
            HotKeyRegistrar.shutdown()
            defaults.removePersistentDomain(forName: name)
        }
        HotKeyRegistrar.configure(binding)
        if panelFirst { try panel.install() }
        HotKeyRegistrar.install(binding.id) { invoked += 1 }
        if !panelFirst { try panel.install() }
        #expect(try sendHotKey(signature: 0x4544_4350, id: 1) == noErr)
        #expect(opened == 1)
        #expect(invoked == 0)
        #expect(try sendHotKey(signature: 0x4544_4954, id: 91) == noErr)
        #expect(invoked == 1)
        #expect(try sendHotKey(signature: 0x5445_5354, id: 91) == eventNotHandledErr)
        #expect(try sendHotKey(signature: 0x4544_4954, id: 92) == eventNotHandledErr)
        #expect(opened == 1)
        #expect(invoked == 1)
        HotKeyRegistrar.clear(binding.id)
        #expect(try sendHotKey(signature: 0x4544_4954, id: 91) == eventNotHandledErr)
    }

    private func sendHotKey(signature: OSType, id: UInt32) throws -> OSStatus {
        var reference: EventRef?
        let created = CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
            EventAttributes(kEventAttributeUserEvent), &reference)
        #expect(created == noErr)
        let event = try #require(reference)
        defer { ReleaseEvent(event) }
        var key = EventHotKeyID(signature: signature, id: id)
        let assigned = SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &key)
        #expect(assigned == noErr)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

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
