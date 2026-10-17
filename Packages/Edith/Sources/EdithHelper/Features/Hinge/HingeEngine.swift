import EdithKit
import Foundation

@MainActor
final class HingeEngine: FeatureModule {
    private let desktop = LiveDesktop()
    private var appliedCalibrate: String?

    init() {
        HingeHotKey.register()
        desktop.reloadPreferences()
        if HingeState.isActive() {
            desktop.setEnabled(true)
        }
    }

    func shutdown() {
        HingeHotKey.unregister()
        desktop.shutDown()
    }

    func applySettings() {
        HingeHotKey.register()
        desktop.reloadPreferences()
        let active = HingeState.isActive()
        if active != desktop.isEnabled {
            desktop.setEnabled(active)
        }
        let request = SharedDefaults.store.string(forKey: HingeSettings.calibrateRequest)
        if let request, request != appliedCalibrate {
            appliedCalibrate = request
            desktop.setOpenPosition()
            SharedDefaults.store.removeObject(forKey: HingeSettings.calibrateRequest)
        }
    }
}
