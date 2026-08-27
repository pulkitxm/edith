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

    @Test func touchGesturesStayNativeWhileContinuousMouseWheelsAreHandled() {
        let discrete = MouseControlSupport.ScrollTraits(
            isContinuous: false, momentumPhase: 0, scrollPhase: 0, scrollCount: 0)
        let mouseDriver = MouseControlSupport.ScrollTraits(
            isContinuous: true, momentumPhase: 0, scrollPhase: 0, scrollCount: 0)
        let touchGesture = MouseControlSupport.ScrollTraits(
            isContinuous: true, momentumPhase: 0, scrollPhase: 1, scrollCount: 1)
        let touchTransition = MouseControlSupport.ScrollTraits(
            isContinuous: true, momentumPhase: 0, scrollPhase: 0, scrollCount: 1)

        #expect(MouseControlSupport.isMouseWheel(discrete, secondsSinceLastGesturePhase: nil))
        #expect(MouseControlSupport.isMouseWheel(mouseDriver, secondsSinceLastGesturePhase: nil))
        #expect(!MouseControlSupport.isMouseWheel(touchGesture, secondsSinceLastGesturePhase: 0))
        #expect(
            !MouseControlSupport.isMouseWheel(touchTransition, secondsSinceLastGesturePhase: 0.2))
        #expect(MouseControlSupport.isMouseWheel(touchTransition, secondsSinceLastGesturePhase: 2))
    }

    @Test func continuousDistanceAndSubpixelCarryPreserveTravel() {
        #expect(MouseControlSupport.continuousDistance(fixedPoint: 2, point: 0, step: 40) == 20)
        #expect(MouseControlSupport.continuousDistance(fixedPoint: 2, point: 5, step: 80) == 10)
        let first = MouseControlSupport.wholePixels(1.4, carry: 0)
        #expect(first.pixels == 1)
        #expect(abs(first.carry - 0.4) < 0.000_001)
        let second = MouseControlSupport.wholePixels(1.4, carry: first.carry)
        #expect(second.pixels == 1)
        #expect(abs(second.carry - 0.8) < 0.000_001)
        #expect(MouseControlSupport.finalPixels(0.2, carry: second.carry) == 1)
        #expect(MouseControlSupport.continuingCarry(0.4, distance: -1) == 0)
    }

    @Test func middleClickRequiresFreshSettledContactsAndHonorsConflicts() {
        #expect(
            MouseControlSupport.middleClickDecision(
                fingerCount: 3, frameAge: 0.01, settledFor: 0.1,
                sinceLastTransform: nil, systemDragEnabled: false) == .transform)
        #expect(
            MouseControlSupport.middleClickDecision(
                fingerCount: 3, frameAge: 0.01, settledFor: 0.01,
                sinceLastTransform: nil, systemDragEnabled: false) == .passThrough)
        #expect(
            MouseControlSupport.middleClickDecision(
                fingerCount: 3, frameAge: 0.3, settledFor: 0.1,
                sinceLastTransform: nil, systemDragEnabled: false) == .passThrough)
        #expect(
            MouseControlSupport.middleClickDecision(
                fingerCount: 3, frameAge: 0.01, settledFor: 0.1,
                sinceLastTransform: 0.1, systemDragEnabled: false) == .suppress)
        #expect(
            MouseControlSupport.middleClickDecision(
                fingerCount: 3, frameAge: 0.01, settledFor: 0.1,
                sinceLastTransform: nil, systemDragEnabled: true) == .passThrough)
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
