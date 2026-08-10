import Foundation

@MainActor
public final class PresenterState: ObservableObject {
    public static let shared = PresenterState()

    @Published public private(set) var manual = false
    @Published public private(set) var autoActive = false
    @Published public private(set) var autoReason: String?

    public var active: Bool {
        FeatureGates.presenterActive(enabled: enabled, manual: manual, autoActive: autoActive)
    }

    @Published public private(set) var enabled = false

    private var localToken: NSObjectProtocol?
    private var settingsToken: NSObjectProtocol?
    private var autoToken: NSObjectProtocol?

    private init() {
        refresh()
        if enabled { startObserving() }
    }

    public func syncEnabled(_ enabled: Bool) {
        if enabled {
            startObserving()
            refresh()
        } else {
            stopObserving()
            if self.enabled { self.enabled = false }
            if manual { manual = false }
            if autoActive { autoActive = false }
            if autoReason != nil { autoReason = nil }
        }
    }

    private func startObserving() {
        guard localToken == nil else { return }
        localToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        settingsToken = IPC.observe(IPC.Name.settingsChanged) { [weak self] in self?.refresh() }
        autoToken = IPC.observe(IPC.Name.presenterAutoActiveChanged) { [weak self] in
            self?.refresh()
        }
    }

    private func stopObserving() {
        if let localToken { NotificationCenter.default.removeObserver(localToken) }
        if let settingsToken { IPC.stopObserving(settingsToken) }
        if let autoToken { IPC.stopObserving(autoToken) }
        localToken = nil
        settingsToken = nil
        autoToken = nil
    }

    private func refresh() {
        let d = SharedDefaults.store
        let newEnabled = d.object(forKey: "presenterEnabled") as? Bool ?? false
        let newManual = newEnabled && d.bool(forKey: "presenterMode")
        let newAutoActive = newEnabled && d.bool(forKey: "presenterAutoActive")
        let newAutoReason = newEnabled ? d.string(forKey: "presenterAutoReason") : nil
        if enabled != newEnabled { enabled = newEnabled }
        if manual != newManual { manual = newManual }
        if autoActive != newAutoActive { autoActive = newAutoActive }
        if autoReason != newAutoReason { autoReason = newAutoReason }
    }
}
