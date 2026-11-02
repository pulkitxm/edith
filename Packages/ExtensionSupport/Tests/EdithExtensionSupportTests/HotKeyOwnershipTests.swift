import Carbon.HIToolbox
import EdithExtensionCore
import Foundation
import Testing

@MainActor @Suite(.serialized) struct HotKeyOwnershipTests {
    @Test func shuttingDownOneImageKeepsAnotherImagesShortcuts() throws {
        let first = try #require(UnsafeRawPointer(bitPattern: 0x7100_1000))
        let second = try #require(UnsafeRawPointer(bitPattern: 0x7100_2000))
        let modifiers = cmdKey | controlKey | optionKey
        HotKeyRegistrar.configure(
            ExtensionHotKeyBinding(
                id: "ownership-first", carbonID: 71, prefix: "ownershipFirst" + UUID().uuidString,
                defaultCode: kVK_F16, defaultModifiers: modifiers), image: first)
        HotKeyRegistrar.configure(
            ExtensionHotKeyBinding(
                id: "ownership-second", carbonID: 72,
                prefix: "ownershipSecond" + UUID().uuidString, defaultCode: kVK_F17,
                defaultModifiers: modifiers), image: second)
        defer { HotKeyRegistrar.shutdown(image: second) }
        var pressed: [String] = []
        #expect(
            HotKeyRegistrar.install("ownership-first", image: first) { pressed.append("first") })
        #expect(
            HotKeyRegistrar.install("ownership-second", image: second) { pressed.append("second") }
        )
        HotKeyRegistrar.shutdown(image: first)
        #expect(!HotKeyRegistrar.isRegistered("ownership-first"))
        #expect(HotKeyRegistrar.isRegistered("ownership-second"))
        #expect(try press(71) == eventNotHandledErr)
        #expect(try press(72) == noErr)
        #expect(pressed == ["second"])
    }

    private func press(_ id: UInt32) throws -> OSStatus {
        var reference: EventRef?
        #expect(
            CreateEvent(
                nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                EventAttributes(kEventAttributeUserEvent), &reference) == noErr)
        let event = try #require(reference)
        defer { ReleaseEvent(event) }
        var key = EventHotKeyID(signature: OSType(0x4544_4954), id: id)
        #expect(
            SetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &key) == noErr)
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}
