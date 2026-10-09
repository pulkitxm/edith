import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class PresenterState {
    private(set) var manual = false
    private(set) var autoActive = false
    private(set) var autoReason: String?
    private(set) var enabled = false
    private(set) var hiddenPrivacy: Set<PresenterPrivacy> = []
    var active: Bool { enabled && (manual || autoActive) }
    private let defaults: UserDefaults
    private let state: ExtensionSharedState?
    private var localToken: NSObjectProtocol?
    private var settingsToken: NSObjectProtocol?
    private var autoToken: NSObjectProtocol?
    private var stopped = false

    init(defaults: UserDefaults = SharedDefaults.store, state: ExtensionSharedState? = .current) {
        self.defaults = defaults
        self.state = state
        localToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        settingsToken = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        autoToken = IPC.observe(IPC.Name.presenterAutoActiveChanged) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard !stopped else { return }
        enabled = defaults.bool(forKey: AppStorageKeys.Presenter.enabled)
        manual = enabled && defaults.bool(forKey: AppStorageKeys.Presenter.mode)
        autoActive = enabled && defaults.bool(forKey: AppStorageKeys.Presenter.autoActive)
        autoReason = enabled ? defaults.string(forKey: AppStorageKeys.Presenter.autoReason) : nil
        hiddenPrivacy = Set(PresenterPrivacy.allCases.filter { $0.isEnabled(in: defaults) })
        publish()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        if let localToken { NotificationCenter.default.removeObserver(localToken) }
        IPC.stopObserving(settingsToken)
        IPC.stopObserving(autoToken)
        localToken = nil
        settingsToken = nil
        autoToken = nil
        enabled = false
        manual = false
        autoActive = false
        autoReason = nil
        publish()
    }

    private func publish() {
        var values = [
            "active": active ? "1" : "0", "manual": manual ? "1" : "0",
            "autoActive": autoActive ? "1" : "0", "autoReason": autoReason ?? "",
            "hideMenuBarNumbers": defaults.bool(forKey: AppStorageKeys.Presenter.hideMenuBarNumbers)
                ? "1" : "0",
        ]
        for category in PresenterPrivacy.allCases {
            let field =
                "blur" + category.rawValue.prefix(1).uppercased() + category.rawValue.dropFirst()
            values[field] = hiddenPrivacy.contains(category) ? "1" : "0"
        }
        try? state?.publish(values)
    }
}
