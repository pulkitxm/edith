import Foundation

@MainActor
public final class PresenterState: ObservableObject {
    public static let shared = PresenterState()

    @Published public private(set) var manual = false
    @Published public private(set) var autoActive = false
    @Published public private(set) var autoReason: String?

    public var active: Bool { manual || autoActive }

    private var localToken: NSObjectProtocol?
    private var settingsToken: NSObjectProtocol?
    private var autoToken: NSObjectProtocol?

    private init() {
        refresh()
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

    private func refresh() {
        let d = SharedDefaults.store
        manual = d.bool(forKey: "presenterMode")
        autoActive = d.bool(forKey: "presenterAutoActive")
        autoReason = d.string(forKey: "presenterAutoReason")
    }
}
