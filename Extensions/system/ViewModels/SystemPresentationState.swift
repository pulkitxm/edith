import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class SystemPresentationState {
    private(set) var hideApps = false
    private let channel: ExtensionSharedState?
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(channel: ExtensionSharedState? = .current) {
        self.channel = channel
        refresh()
        observer = channel?.observe { [weak self] owner in
            guard owner == "presenter" else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !stopped else { return }
        let values = channel?.values(for: "presenter") ?? [:]
        hideApps = values["active"] == "1" && values["blurRunningApps"] != "0"
    }

    func shutdown() {
        stopped = true
        channel?.stopObserving(observer)
        observer = nil
        hideApps = false
    }
}
