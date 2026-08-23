import Testing

@testable import Edith

@Suite struct ExtensionPreviewMotionPolicyTests {
    @Test func restsUntilHovered() {
        #expect(!ExtensionPreviewMotionPolicy.animates(hovering: false, reduceMotion: false))
        #expect(ExtensionPreviewMotionPolicy.animates(hovering: true, reduceMotion: false))
    }

    @Test func reduceMotionAlwaysDisablesAnimation() {
        #expect(!ExtensionPreviewMotionPolicy.animates(hovering: false, reduceMotion: true))
        #expect(!ExtensionPreviewMotionPolicy.animates(hovering: true, reduceMotion: true))
    }

    @Test func restingFrameAndCadenceRemainStable() {
        #expect(ExtensionPreviewMotionPolicy.restingPhase == 1.1)
        #expect(ExtensionPreviewMotionPolicy.frameInterval == 1.0 / 30)
    }
}
