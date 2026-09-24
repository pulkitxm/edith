import EdithKit
import Foundation

@MainActor
enum HerdrOpenBridge {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = IPC.observe(IPC.Name.requestOpenHerdrAgent) {
            MainActor.assumeIsolated { openPending() }
        }
        openPending()
    }

    static func openPending(
        store: HerdrStore? = nil, defaults: UserDefaults = SharedDefaults.store
    ) {
        guard let request = HerdrOpenRequests.take(defaults: defaults) else { return }
        defaults.set(
            MainDestination.herdr.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
        MainWindow.open()
        let target = store ?? .shared
        Task { await target.open(request) }
    }
}
