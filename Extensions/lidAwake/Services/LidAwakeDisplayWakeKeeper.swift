import IOKit.pwr_mgt

final class LidAwakeDisplayWakeKeeper {
    private let enabled: Bool
    init(enabled: Bool = true) { self.enabled = enabled }
    private var assertionID: IOPMAssertionID = 0

    func prevent() {
        guard enabled, assertionID == 0 else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Edith lid awake" as CFString,
            &assertionID)
        if result != kIOReturnSuccess { assertionID = 0 }
    }

    func allow() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }
}
