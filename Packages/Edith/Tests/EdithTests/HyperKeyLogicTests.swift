import CoreGraphics
import Testing

@testable import EdithKit

@Suite struct HyperKeyLogicTests {
    @Test func capsLockKeyCodeRecognized() {
        #expect(HyperKeyLogic.isCapsLock(keyCode: 57))
        #expect(!HyperKeyLogic.isCapsLock(keyCode: 0))
    }

    @Test func mergesHyperFlagsWhenActive() {
        let merged = HyperKeyLogic.mergedFlags(current: [], hyperActive: true)
        #expect(merged.contains(.maskCommand))
        #expect(merged.contains(.maskAlternate))
        #expect(merged.contains(.maskControl))
        #expect(merged.contains(.maskShift))
    }

    @Test func leavesFlagsUntouchedWhenInactive() {
        let merged = HyperKeyLogic.mergedFlags(current: [.maskShift], hyperActive: false)
        #expect(merged == [.maskShift])
    }

    @Test func preservesExistingFlagsWhileMerging() {
        let merged = HyperKeyLogic.mergedFlags(current: [.maskNumericPad], hyperActive: true)
        #expect(merged.contains(.maskNumericPad))
        #expect(merged.contains(.maskCommand))
    }
}
