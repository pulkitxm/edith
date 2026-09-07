import EdithKit
import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwakeStore: FeatureModule {
    private(set) var preventingSleep = false
    private var assertionID: IOPMAssertionID = 0

    init() {
        syncPreventSleep()
    }

    func syncPreventSleep() {
        let want = SharedDefaults.store.bool(forKey: AppStorageKeys.General.preventSleep)
        guard want != preventingSleep else { return }
        if want {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Edith: Keep Awake is on" as CFString,
                &assertionID)
            preventingSleep = result == kIOReturnSuccess
        } else {
            shutdown()
        }
    }

    func shutdown() {
        guard preventingSleep else { return }
        IOPMAssertionRelease(assertionID)
        preventingSleep = false
    }
}
