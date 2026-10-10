import AppKit
import Carbon.HIToolbox

@MainActor
final class GhosttySecureInput: NSObject {
    typealias Transition = (Bool) -> Bool

    static let shared = GhosttySecureInput(applicationActive: NSApp.isActive)

    private let center: NotificationCenter
    private let transition: Transition
    private var scoped: [ObjectIdentifier: Bool] = [:]
    private var hostActive: [ObjectIdentifier: Bool] = [:]
    private var applicationActive: Bool
    private(set) var enabled = false

    init(
        applicationActive: Bool,
        center: NotificationCenter = .default,
        transition: @escaping Transition = { enabled in
            let status = enabled ? EnableSecureEventInput() : DisableSecureEventInput()
            return status == noErr
        }
    ) {
        self.applicationActive = applicationActive
        self.center = center
        self.transition = transition
        super.init()
        center.addObserver(
            self, selector: #selector(applicationDidResign),
            name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        center.removeObserver(self)
        if enabled { _ = transition(false) }
    }

    func setScoped(_ object: ObjectIdentifier, focused: Bool, applicationActive: Bool? = nil) {
        scoped[object] = focused
        hostActive[object] = applicationActive
        apply()
    }

    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        hostActive[object] = nil
        apply()
    }

    private var desired: Bool {
        scoped.contains { object, focused in focused && (hostActive[object] ?? applicationActive) }
    }

    private func apply() {
        let desired = desired
        guard enabled != desired else { return }
        if transition(desired) { enabled = desired }
    }

    @objc private func applicationDidResign() {
        applicationActive = false
        apply()
    }

    @objc private func applicationDidBecomeActive() {
        applicationActive = true
        apply()
    }
}
