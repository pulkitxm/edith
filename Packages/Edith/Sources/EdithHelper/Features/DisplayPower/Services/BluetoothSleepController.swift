import AppKit
import EdithKit
import IOKit

@MainActor
final class BluetoothSleepController {
    private typealias PowerGet = @convention(c) () -> Int32
    private typealias PowerSet = @convention(c) (Int32) -> Void

    private(set) var supported: Bool
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private let changed: () -> Void

    init(changed: @escaping () -> Void) {
        supported = Self.controllerPower != nil && Self.hasController
        self.changed = changed
    }

    func sync() {
        let enabled = SharedDefaults.store.bool(
            forKey: AppStorageKeys.DisplayPower.bluetoothOffDuringSleep)
        if enabled, supported {
            if !sleeping { Self.restoreIfOwed() }
            start()
        } else {
            stop()
            sleeping = false
            Self.restoreIfOwed()
        }
        changed()
    }

    func shutdown() {
        stop()
        Self.restoreIfOwed()
        changed()
    }

    static func restoreIfOwed() {
        let defaults = SharedDefaults.store
        let owed = defaults.bool(forKey: AppStorageKeys.DisplayPower.bluetoothRestorePending)
        let restore = DisplayPowerPolicy.shouldRestoreBluetooth(
            owesRestore: owed, isPoweredOn: isPoweredOn)
        defaults.set(false, forKey: AppStorageKeys.DisplayPower.bluetoothRestorePending)
        if restore { setPowered(true) }
    }

    private func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleeping = false
                    Self.restoreIfOwed()
                    self?.changed()
                }
            },
        ]
    }

    private func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func willSleep() {
        sleeping = true
        let plan = DisplayPowerPolicy.bluetoothSleepPlan(isPoweredOn: Self.isPoweredOn)
        SharedDefaults.store.set(
            plan.owesRestore, forKey: AppStorageKeys.DisplayPower.bluetoothRestorePending)
        if plan.powersOff { Self.setPowered(false) }
        changed()
    }

    private static let hasController: Bool = {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOBluetoothHCIController"))
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }()

    private static let controllerPower: (get: PowerGet, set: PowerSet)? = {
        let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        guard let handle = dlopen(path, RTLD_LAZY),
            let get = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
            let set = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState")
        else { return nil }
        return (
            unsafeBitCast(get, to: PowerGet.self),
            unsafeBitCast(set, to: PowerSet.self)
        )
    }()

    private static var isPoweredOn: Bool {
        controllerPower?.get() != 0
    }

    private static func setPowered(_ on: Bool) {
        controllerPower?.set(on ? 1 : 0)
    }
}
