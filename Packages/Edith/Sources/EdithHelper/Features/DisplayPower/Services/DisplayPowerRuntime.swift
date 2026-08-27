import EdithKit

@MainActor
final class DisplayPowerRuntime: FeatureModule {
    private var brightness: DisplayBrightnessController!
    private var xdr: XDRBrightnessController!
    private var bluetooth: BluetoothSleepController!

    required init() {
        brightness = DisplayBrightnessController { [weak self] in self?.publishSnapshot() }
        xdr = XDRBrightnessController { [weak self] in self?.publishSnapshot() }
        bluetooth = BluetoothSleepController { [weak self] in self?.publishSnapshot() }
        brightness.start()
        xdr.sync()
        bluetooth.sync()
        publishSnapshot()
    }

    func syncSettings() {
        brightness.applyConfiguredLevels()
        xdr.sync()
        bluetooth.sync()
        publishSnapshot()
    }

    func shutdown() {
        brightness.shutdown()
        xdr.shutdown()
        bluetooth.shutdown()
        publishSnapshot()
    }

    private func publishSnapshot() {
        guard brightness != nil, xdr != nil, bluetooth != nil else { return }
        DisplayPowerOperationExecution.saveSnapshot(
            DisplayPowerSnapshot(
                displays: brightness.displays, xdrSupported: xdr.supported,
                xdrBoosting: xdr.boosting, bluetoothSupported: bluetooth.supported,
                bluetoothOffDuringSleep: SharedDefaults.store.bool(
                    forKey: AppStorageKeys.DisplayPower.bluetoothOffDuringSleep),
                bluetoothRestorePending: SharedDefaults.store.bool(
                    forKey: AppStorageKeys.DisplayPower.bluetoothRestorePending)))
    }
}
