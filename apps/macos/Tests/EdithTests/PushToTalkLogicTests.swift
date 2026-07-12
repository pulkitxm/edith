import Carbon.HIToolbox
import CoreGraphics
import Testing

@testable import EdithKit

@Suite struct CarbonModifiersTests {
    @Test func mapsEachCarbonModifierToItsCGFlag() {
        #expect(CarbonModifiers.toCGEventFlags(cmdKey) == .maskCommand)
        #expect(CarbonModifiers.toCGEventFlags(shiftKey) == .maskShift)
        #expect(CarbonModifiers.toCGEventFlags(optionKey) == .maskAlternate)
        #expect(CarbonModifiers.toCGEventFlags(controlKey) == .maskControl)
    }

    @Test func combinesModifiers() {
        let flags = CarbonModifiers.toCGEventFlags(controlKey | optionKey)
        #expect(flags == [.maskControl, .maskAlternate])
    }

    @Test func zeroMapsToEmpty() {
        #expect(CarbonModifiers.toCGEventFlags(0) == [])
    }
}

@Suite struct PushToTalkLogicTests {
    @Test func matchesExactKeyCodeAndModifiers() {
        #expect(
            PushToTalkLogic.matches(
                keyCode: 46, flags: [.maskControl, .maskAlternate], targetKeyCode: 46,
                targetFlags: [.maskControl, .maskAlternate]))
    }

    @Test func rejectsDifferentKeyCode() {
        #expect(
            !PushToTalkLogic.matches(
                keyCode: 1, flags: [.maskControl, .maskAlternate], targetKeyCode: 46,
                targetFlags: [.maskControl, .maskAlternate]))
    }

    @Test func rejectsMissingModifier() {
        #expect(
            !PushToTalkLogic.matches(
                keyCode: 46, flags: [.maskControl], targetKeyCode: 46,
                targetFlags: [.maskControl, .maskAlternate]))
    }

    @Test func rejectsExtraModifier() {
        #expect(
            !PushToTalkLogic.matches(
                keyCode: 46, flags: [.maskControl, .maskAlternate, .maskShift], targetKeyCode: 46,
                targetFlags: [.maskControl, .maskAlternate]))
    }

    @Test func ignoresIrrelevantFlagsLikeCapsLockOrFn() {
        let noisyFlags: CGEventFlags = [
            .maskControl, .maskAlternate, .maskAlphaShift, .maskSecondaryFn,
        ]
        #expect(
            PushToTalkLogic.matches(
                keyCode: 46, flags: noisyFlags, targetKeyCode: 46,
                targetFlags: [.maskControl, .maskAlternate]))
    }
}
