import EdithExtensionSupport
import Observation
import SwiftUI

@MainActor
@Observable
final class UIScaleStore {
    static let shared = UIScaleStore()
    private(set) var factor: Double = 1

    private init() {}

    func update(_ value: Double) {
        guard factor != value else { return }
        factor = value
    }
}

public enum UIScale {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Double = 1

    @MainActor
    public static func apply(_ value: Double) {
        let clamped = WindowZoom.clamp(value)
        lock.withLock { cached = clamped }
        UIScaleStore.shared.update(clamped)
    }

    @MainActor
    public static func install(from defaults: UserDefaults) {
        let stored =
            (defaults.object(forKey: WindowZoom.defaultsKey) as? NSNumber)?.doubleValue ?? 1
        apply(stored)
    }

    public static var current: Double { readFactor() }

    public static func pt(_ value: Double) -> Double {
        value * readFactor()
    }

    public static var controlSize: ControlSize {
        switch readFactor() {
        case ..<1.15: .regular
        case ..<1.45: .large
        default: .extraLarge
        }
    }

    private static func readFactor() -> Double {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { UIScaleStore.shared.factor }
        }
        return lock.withLock { cached }
    }
}
