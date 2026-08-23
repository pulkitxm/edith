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

    @Test func hoverUsesOneTransitionFrameInsteadOfAContinuousTimeline() {
        #expect(ExtensionPreviewMotionPolicy.restingPhase == 1.1)
        #expect(ExtensionPreviewMotionPolicy.hoverPhase == 2.2)
        #expect(
            ExtensionPreviewMotionPolicy.phase(hovering: false, reduceMotion: false)
                == ExtensionPreviewMotionPolicy.restingPhase)
        #expect(
            ExtensionPreviewMotionPolicy.phase(hovering: true, reduceMotion: false)
                == ExtensionPreviewMotionPolicy.hoverPhase)
        #expect(
            ExtensionPreviewMotionPolicy.phase(hovering: true, reduceMotion: true)
                == ExtensionPreviewMotionPolicy.restingPhase)
    }
}
