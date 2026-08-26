import SwiftUI
import Testing
@testable import EdithKit

@Suite struct MotionTests {
    @Test func preservesBaseAnimationWhenReduceMotionIsOff() {
        let base = Animation.snappy(duration: 0.7)
        #expect(Motion.animation(base, reduceMotion: false) == base)
    }

    @Test func removesAnimationWhenReduceMotionIsOn() {
        let base = Animation.smooth(duration: 0.7)
        #expect(Motion.animation(base, reduceMotion: true) == nil)
    }
}
