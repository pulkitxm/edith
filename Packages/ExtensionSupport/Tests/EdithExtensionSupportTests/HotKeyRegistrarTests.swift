import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import EdithExtensionSupport

@Suite(.serialized) @MainActor struct HotKeyRegistrarTests {
    private let modifiers = cmdKey | controlKey | optionKey

    private func binding(
        _ name: String, carbonID: UInt32, code: Int, prefix: String? = nil
    ) -> ExtensionHotKeyBinding {
        ExtensionHotKeyBinding(
            id: name, carbonID: carbonID, prefix: prefix ?? "lifecycleTest" + name,
            defaultCode: code, defaultModifiers: modifiers)
    }

    private func isHeld(code: Int, modifiers: Int) -> Bool {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(
            UInt32(code), UInt32(modifiers),
            EventHotKeyID(signature: OSType(0x5445_5354), id: 1), GetApplicationEventTarget(), 0,
            &reference)
        if result == noErr, let reference {
            UnregisterEventHotKey(reference)
            return false
        }
        return result == OSStatus(eventHotKeyExistsErr)
    }

    private func press(carbonID: UInt32) -> OSStatus {
        var reference: EventRef?
        CreateEvent(
            nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
            EventAttributes(kEventAttributeUserEvent), &reference)
        guard let event = reference else { return OSStatus(paramErr) }
        defer { ReleaseEvent(event) }
        var key = EventHotKeyID(signature: OSType(0x4544_4954), id: carbonID)
        SetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &key)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    private func prepare() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        HotKeyRegistrar.shutdown()
    }

    @Test func aShortcutIsLiveRightAfterInstallAndReleasedOnClear() {
        prepare()
        defer { HotKeyRegistrar.shutdown() }
        HotKeyRegistrar.configure(binding("alpha", carbonID: 71, code: kVK_F16))
        #expect(!isHeld(code: kVK_F16, modifiers: modifiers))
        var fired = 0
        #expect(HotKeyRegistrar.install("alpha") { fired += 1 })
        #expect(HotKeyRegistrar.isRegistered("alpha"))
        #expect(isHeld(code: kVK_F16, modifiers: modifiers))
        #expect(press(carbonID: 71) == noErr)
        #expect(fired == 1)
        HotKeyRegistrar.clear("alpha")
        #expect(!HotKeyRegistrar.isRegistered("alpha"))
        #expect(!isHeld(code: kVK_F16, modifiers: modifiers))
        #expect(press(carbonID: 71) == OSStatus(eventNotHandledErr))
        #expect(fired == 1)
    }

    @Test func anExtensionThatIsEnabledAgainRegistersItsShortcutAgain() {
        prepare()
        defer { HotKeyRegistrar.shutdown() }
        for round in 1...3 {
            HotKeyRegistrar.configure(binding("alpha", carbonID: 71, code: kVK_F16))
            var fired = 0
            #expect(HotKeyRegistrar.install("alpha") { fired += 1 }, "round \(round)")
            #expect(isHeld(code: kVK_F16, modifiers: modifiers), "round \(round)")
            #expect(press(carbonID: 71) == noErr, "round \(round)")
            #expect(fired == 1, "round \(round)")
            HotKeyRegistrar.shutdown()
            #expect(!isHeld(code: kVK_F16, modifiers: modifiers), "round \(round)")
        }
    }

    @Test func changingTheStoredShortcutMovesTheRegistration() {
        prepare()
        let prefix = "lifecycleTestMoving"
        let defaults = SharedDefaults.store
        defer {
            HotKeyRegistrar.shutdown()
            defaults.removeObject(forKey: prefix + "Code")
            defaults.removeObject(forKey: prefix + "Mods")
        }
        HotKeyRegistrar.configure(binding("moving", carbonID: 72, code: kVK_F16, prefix: prefix))
        HotKeyRegistrar.install("moving") {}
        #expect(isHeld(code: kVK_F16, modifiers: modifiers))
        defaults.set(kVK_F17, forKey: prefix + "Code")
        defaults.set(modifiers, forKey: prefix + "Mods")
        HotKeyRegistrar.install("moving") {}
        #expect(!isHeld(code: kVK_F16, modifiers: modifiers))
        #expect(isHeld(code: kVK_F17, modifiers: modifiers))
        #expect(HotKeyRegistrar.isRegistered("moving"))
    }

    @Test func rebindingToAShortcutAnotherExtensionOwnsKeepsTheWorkingOne() {
        prepare()
        let prefix = "lifecycleTestRebinding"
        let defaults = SharedDefaults.store
        defer {
            HotKeyRegistrar.shutdown()
            defaults.removeObject(forKey: prefix + "Code")
            defaults.removeObject(forKey: prefix + "Mods")
        }
        HotKeyRegistrar.configure(binding("alpha", carbonID: 71, code: kVK_F16))
        HotKeyRegistrar.configure(binding("moving", carbonID: 72, code: kVK_F17, prefix: prefix))
        var moving = 0
        HotKeyRegistrar.install("alpha") {}
        HotKeyRegistrar.install("moving") { moving += 1 }
        defaults.set(kVK_F16, forKey: prefix + "Code")
        defaults.set(modifiers, forKey: prefix + "Mods")
        #expect(!HotKeyRegistrar.install("moving") { moving += 10 })
        #expect(HotKeyRegistrar.isRegistered("moving"))
        #expect(isHeld(code: kVK_F17, modifiers: modifiers))
        #expect(press(carbonID: 72) == noErr)
        #expect(moving == 1)
    }

    @Test func installingTheSameShortcutAgainOnlyReplacesTheAction() {
        prepare()
        defer { HotKeyRegistrar.shutdown() }
        HotKeyRegistrar.configure(binding("alpha", carbonID: 71, code: kVK_F16))
        var first = 0
        var second = 0
        #expect(HotKeyRegistrar.install("alpha") { first += 1 })
        #expect(HotKeyRegistrar.install("alpha") { second += 1 })
        #expect(isHeld(code: kVK_F16, modifiers: modifiers))
        #expect(press(carbonID: 71) == noErr)
        #expect((first, second) == (0, 1))
    }

    @Test func extensionsKeepIndependentShortcutsWhenOneStops() {
        prepare()
        defer { HotKeyRegistrar.shutdown() }
        HotKeyRegistrar.configure(binding("alpha", carbonID: 71, code: kVK_F16))
        HotKeyRegistrar.configure(binding("beta", carbonID: 73, code: kVK_F17))
        var alpha = 0
        var beta = 0
        HotKeyRegistrar.install("alpha") { alpha += 1 }
        HotKeyRegistrar.install("beta") { beta += 1 }
        #expect(press(carbonID: 73) == noErr)
        #expect(press(carbonID: 71) == noErr)
        #expect((alpha, beta) == (1, 1))
        HotKeyRegistrar.clear("alpha")
        #expect(isHeld(code: kVK_F17, modifiers: modifiers))
        #expect(press(carbonID: 73) == noErr)
        #expect(press(carbonID: 71) == OSStatus(eventNotHandledErr))
        #expect((alpha, beta) == (1, 2))
    }

    @Test func twoExtensionsOnTheSameKeysKeepTheFirstAndReportTheSecondAsFailed() {
        prepare()
        defer { HotKeyRegistrar.shutdown() }
        HotKeyRegistrar.configure(binding("alpha", carbonID: 71, code: kVK_F16))
        HotKeyRegistrar.configure(binding("beta", carbonID: 73, code: kVK_F16))
        var alpha = 0
        var beta = 0
        #expect(HotKeyRegistrar.install("alpha") { alpha += 1 })
        #expect(!HotKeyRegistrar.install("beta") { beta += 1 })
        #expect(HotKeyRegistrar.isRegistered("alpha"))
        #expect(!HotKeyRegistrar.isRegistered("beta"))
        #expect(press(carbonID: 71) == noErr)
        #expect(press(carbonID: 73) == OSStatus(eventNotHandledErr))
        #expect((alpha, beta) == (1, 0))
    }

    @Test func installingWithoutAConfiguredBindingFails() {
        prepare()
        #expect(!HotKeyRegistrar.install("unconfigured") {})
        #expect(!HotKeyRegistrar.isRegistered("unconfigured"))
    }
}
