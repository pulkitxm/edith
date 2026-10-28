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
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

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
        apply(hideApps: values["active"] == "1" && values["blurRunningApps"] != "0")
    }

    func waitForChange(from current: Bool, timeout: Duration) async -> Bool {
        guard hideApps == current, !stopped else { return hideApps }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.release(id)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(id) }
        }
        timer.cancel()
        return hideApps
    }

    private func release(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func releaseAll() {
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume() }
    }

    func apply(hideApps: Bool) {
        guard !stopped else { return }
        guard self.hideApps != hideApps else { return }
        self.hideApps = hideApps
        releaseAll()
    }

    func shutdown() {
        stopped = true
        channel?.stopObserving(observer)
        observer = nil
        hideApps = false
        releaseAll()
    }
}
