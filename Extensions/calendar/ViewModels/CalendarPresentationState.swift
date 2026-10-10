import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class CalendarPresentationState {
    private(set) var blurEvents = false
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
        blurEvents = values["active"] == "1" && values["blurCalendar"] != "0"
    }

    func shutdown() {
        stopped = true
        channel?.stopObserving(observer)
        observer = nil
        blurEvents = false
    }
}
