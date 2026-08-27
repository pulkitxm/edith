import Foundation
import Testing

@testable import EdithKit

@Suite struct MouseControlTests {
    @Test func storedRangesRecoverFromMissingAndDamagedValues() {
        #expect(MouseControlSupport.sanitizedScrollStep(0) == 40)
        #expect(MouseControlSupport.sanitizedScrollStep(10) == 20)
        #expect(MouseControlSupport.sanitizedScrollStep(120) == 100)
        #expect(MouseControlSupport.sanitizedFocusDelay(0) == 300)
        #expect(MouseControlSupport.sanitizedFocusDelay(20) == 100)
        #expect(MouseControlSupport.sanitizedFocusDelay(2_000) == 1_000)
    }

    @Test func shiftAndDirectionSettingsTransformAxesIndependently() {
        let ordinary = MouseControlSupport.axes(
            vertical: 2, horizontal: -1, shiftPressed: false,
            reverseVertical: true, reverseHorizontal: false)
        #expect(ordinary.vertical == -2)
        #expect(ordinary.horizontal == -1)

        let shifted = MouseControlSupport.axes(
            vertical: 2, horizontal: 0, shiftPressed: true,
            reverseVertical: true, reverseHorizontal: true)
        #expect(shifted.vertical == 0)
        #expect(shifted.horizontal == -2)
    }

    @Test func directionChangesDropThePreviousGlideTail() {
        #expect(MouseControlSupport.nextRemaining(current: 40, added: 20) == 60)
        #expect(MouseControlSupport.nextRemaining(current: 40, added: -20) == -20)
        #expect(MouseControlSupport.frameDelta(100) == 20)
        #expect(MouseControlSupport.frameDelta(-100) == -20)
    }

    @Test func automaticSideButtonsResolveWithoutOverridingExplicitMappings() {
        #expect(
            MouseControlSupport.resolvedAction(
                buttonNumber: 3, stored: "automatic", sideNavigation: true) == .back)
        #expect(
            MouseControlSupport.resolvedAction(
                buttonNumber: 4, stored: "automatic", sideNavigation: true) == .forward)
        #expect(
            MouseControlSupport.resolvedAction(
                buttonNumber: 3, stored: "automatic", sideNavigation: false) == .passThrough)
        #expect(
            MouseControlSupport.resolvedAction(
                buttonNumber: 3, stored: "middleClick", sideNavigation: true) == .middleClick)
        #expect(
            MouseControlSupport.resolvedAction(
                buttonNumber: 5, stored: nil, sideNavigation: true) == .passThrough)
    }

    @Test func exclusionsAreTrimmedNormalizedAndDeduplicated() {
        let values = MouseControlSupport.excludedBundleIDs(
            " com.Example.Game,com.example.design, com.example.game ")
        #expect(values == ["com.example.game", "com.example.design"])
        #expect(MouseControlSupport.isExcluded("COM.EXAMPLE.GAME", from: values))
        #expect(!MouseControlSupport.isExcluded("com.example.browser", from: values))
    }

    @Test func liveAdapterRejectsInvalidStoredActions() {
        let suite = "MouseControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(
            ExtensionLiveAdapters.mouseControlsReadiness(defaults: defaults)
                == .ready("Mouse wheel, pointer focus, and extra-button settings are valid."))
        defaults.set("invalid", forKey: AppStorageKeys.Mouse.button6Action)
        #expect(
            ExtensionLiveAdapters.mouseControlsReadiness(defaults: defaults)
                == .needsSetup(
                    "A stored scroll distance, focus delay, or button action is invalid."))
    }
}
