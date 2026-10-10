import CoreFoundation
import Foundation
import IOKit.ps

public struct ExtensionAmbientCadence: Equatable, Sendable {
    public let ambient: TimeInterval?
    public let live: TimeInterval?

    public init(ambient: TimeInterval? = nil, live: TimeInterval? = nil) {
        self.ambient = ambient
        self.live = live
    }

    public func interval(
        subscribers: Int, pauseAmbient: Bool, constrained: Bool = false
    ) -> TimeInterval? {
        let interval: TimeInterval?
        if subscribers > 0, let live {
            interval = live
        } else if pauseAmbient {
            interval = nil
        } else {
            interval = ambient.map { constrained ? $0 * 3 : $0 }
        }
        guard let interval, interval.isFinite, interval > 0 else { return nil }
        return interval
    }
}

public enum ExtensionAmbientPolicyError: Error, Equatable, Sendable {
    case invalidContext, observationUnavailable
}

@MainActor public final class ExtensionAmbientPolicy {
    public typealias BatteryObservation =
        @MainActor (@escaping @MainActor () -> Void) throws -> (@MainActor () -> Void)

    private final class BatteryCallback {
        var change: (@MainActor () -> Void)?
        init(change: @escaping @MainActor () -> Void) { self.change = change }
    }
    public private(set) var pauseAmbientOnBattery = false
    private let jobs: [String: ExtensionAmbientCadence]
    private let onBattery: @MainActor () -> Bool
    private let constrained: @MainActor () -> Bool
    private let notificationCenter: NotificationCenter
    private let observeBatteryChanges: BatteryObservation
    private var stopBatteryObservation: (@MainActor () -> Void)?
    private var counts: [String: Int]
    private var tokens: [NSObjectProtocol] = []
    private var onChange: (@MainActor () -> Void)?

    public init(
        jobs: [String: ExtensionAmbientCadence],
        onBattery: @escaping @MainActor () -> Bool = {
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                return false
            }
            return IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
                == kIOPMBatteryPowerKey
        },
        constrained: @escaping @MainActor () -> Bool = {
            let process = ProcessInfo.processInfo
            return process.isLowPowerModeEnabled || process.thermalState == .serious
                || process.thermalState == .critical
        },
        notificationCenter: NotificationCenter = .default,
        observeBatteryChanges: @escaping BatteryObservation = ExtensionAmbientPolicy
            .observeBatteryChanges
    ) {
        self.jobs = jobs
        self.onBattery = onBattery
        self.constrained = constrained
        self.notificationCenter = notificationCenter
        self.observeBatteryChanges = observeBatteryChanges
        counts = jobs.mapValues { _ in 0 }
    }

    deinit {
        if let stop = stopBatteryObservation { Task { @MainActor in stop() } }
        for token in tokens { notificationCenter.removeObserver(token) }
    }

    public func apply(context: NSDictionary) throws {
        guard let policy = context["ambientPolicy"] as? NSDictionary,
            let keys = policy.allKeys as? [String],
            Set(keys) == ["pauseAmbientOnBattery", "subscribers"],
            let scalar = policy["pauseAmbientOnBattery"] as? NSNumber,
            CFGetTypeID(scalar) == CFBooleanGetTypeID(),
            let subscribers = policy["subscribers"] as? NSDictionary,
            let names = subscribers.allKeys as? [String], Set(names) == Set(jobs.keys)
        else { throw ExtensionAmbientPolicyError.invalidContext }
        var next: [String: Int] = [:]
        for name in names {
            guard let count = subscribers[name] as? NSNumber,
                CFGetTypeID(count) != CFBooleanGetTypeID(),
                ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(
                    String(cString: count.objCType)),
                count.doubleValue >= 0, count.doubleValue <= 128
            else { throw ExtensionAmbientPolicyError.invalidContext }
            next[name] = count.intValue
        }
        let changed = pauseAmbientOnBattery != scalar.boolValue || counts != next
        pauseAmbientOnBattery = scalar.boolValue
        counts = next
        if changed { onChange?() }
    }

    public func subscribers(for job: String) -> Int { counts[job] ?? 0 }

    public func interval(for job: String) -> TimeInterval? {
        jobs[job]?.interval(
            subscribers: subscribers(for: job), pauseAmbient: pauseAmbientOnBattery && onBattery(),
            constrained: constrained())
    }

    public func start(onChange: @escaping @MainActor () -> Void) throws {
        guard self.onChange == nil else { return }
        let stop = try observeBatteryChanges { [weak self] in self?.onChange?() }
        self.onChange = onChange
        stopBatteryObservation = stop
        for name in [
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ] {
            tokens.append(
                notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?() }
                })
        }
    }

    public static func observeBatteryChanges(
        _ change: @escaping @MainActor () -> Void
    ) throws -> (@MainActor () -> Void) {
        let callback = BatteryCallback(change: change)
        guard
            let source = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    let callback = Unmanaged<BatteryCallback>.fromOpaque(context)
                        .takeUnretainedValue()
                    MainActor.assumeIsolated { callback.change?() }
                }, Unmanaged.passUnretained(callback).toOpaque())?.takeRetainedValue()
        else { throw ExtensionAmbientPolicyError.observationUnavailable }
        let loop = CFRunLoopGetMain()
        CFRunLoopAddSource(loop, source, .commonModes)
        return {
            callback.change = nil
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }

    public func stop() {
        onChange = nil
        stopBatteryObservation?()
        stopBatteryObservation = nil
        for token in tokens { notificationCenter.removeObserver(token) }
        tokens = []
    }
}
