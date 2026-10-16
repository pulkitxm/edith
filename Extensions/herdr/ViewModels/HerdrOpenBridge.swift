import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
enum HerdrOpenBridge {
    private static var observer: NSObjectProtocol?

    static func shutdown() {
        HerdrIPC.stopObserving(observer)
        observer = nil
    }

    static func install() {
        guard observer == nil else { return }
        observer = HerdrIPC.observe(HerdrIPC.Name.requestOpenHerdrAgent) {
            MainActor.assumeIsolated { openPending() }
        }
        openPending()
    }

    static func openPending(
        store: HerdrStore? = nil, defaults: UserDefaults = SharedDefaults.store
    ) {
        guard let request = HerdrOpenRequests.take(defaults: defaults) else { return }
        ExtensionPresentation.showWindow()
        let target = store ?? .shared
        HerdrWorkOwnership.start { await target.open(request) }
    }
}
