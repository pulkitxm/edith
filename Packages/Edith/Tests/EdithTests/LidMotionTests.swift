import Foundation
import Testing

@testable import EdithKit

@Suite struct LidMotionTests {
    @Test func anOpenLidStaysFlat() {
        let motion = LidMotion(openAngle: 100)
        motion.setEnabled(true)
        motion.receive(100, at: 1)
        #expect(motion.sample(at: 1) == 0)
        #expect(!motion.isClosing)
    }

    @Test func closingPastTheOpenPositionStartsTheFold() {
        let motion = LidMotion(openAngle: 100)
        motion.setEnabled(true)
        motion.receive(100, at: 1)
        let update = motion.receive(80, at: 1.2)
        #expect(update.beganClosing)
        #expect(motion.isClosing)
        let progress = motion.sample(at: 1.25)
        #expect(progress > 0)
        #expect(progress <= 1)
    }

    @Test func calibrationRejectsANearlyClosedLid() {
        let motion = LidMotion(openAngle: 100)
        motion.receive(20, at: 1)
        #expect(motion.calibrate() == nil)
        motion.receive(92, at: 2)
        #expect(motion.calibrate() == 92)
    }

    @Test func aMissingSensorClearsTheFold() {
        let motion = LidMotion(openAngle: 100)
        motion.setEnabled(true)
        motion.receive(70, at: 1)
        _ = motion.sample(at: 1.2)
        let update = motion.receive(nil, at: 1.4)
        #expect(update.availabilityChanged)
        #expect(!update.available)
        #expect(motion.sample(at: 1.5) == 0)
    }
}
