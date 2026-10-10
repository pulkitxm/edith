import Foundation
import Observation

@MainActor
@Observable
public final class DashboardRefreshBridge {
    public private(set) var updating = false
    public private(set) var log = ""

    @ObservationIgnored private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private let logURL: URL
    private let requestUsageRefresh: @MainActor () -> Void
    @ObservationIgnored private nonisolated(unsafe) var tailTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var logVisible = false

    public init(
        logURL: URL = Repo.dataDir.appendingPathComponent("refresh.log"),
        requestUsageRefresh: @escaping @MainActor () -> Void = {
            _ = try? UsageWorkerOperations.requestRefresh()
        }
    ) {
        self.logURL = logURL
        self.requestUsageRefresh = requestUsageRefresh
        tokens.append(
            UsageEvents.observe(UsageEvents.refreshStarted) { [weak self] in
                self?.beginTail()
            })
        tokens.append(
            UsageEvents.observe(UsageEvents.refreshFinished) { [weak self] in
                self?.endTail()
            })
    }

    deinit {
        tailTimer?.invalidate()
        reloadTask?.cancel()
        for token in tokens { UsageEvents.stopObserving(token) }
    }

    public func requestRefresh() {
        requestUsageRefresh()
    }

    public func setLogVisible(_ visible: Bool) {
        guard visible != logVisible else { return }
        logVisible = visible
        if visible {
            reloadLog()
            if updating { startTailTimer() }
        } else {
            stopTailTimer()
            reloadTask?.cancel()
            reloadTask = nil
        }
    }

    public func awaitPendingLogLoad() async {
        await reloadTask?.value
    }

    private func beginTail() {
        updating = true
        guard logVisible else { return }
        reloadLog()
        startTailTimer()
    }

    private func endTail() {
        stopTailTimer()
        updating = false
        if logVisible { reloadLog() }
    }

    private func startTailTimer() {
        tailTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadLog() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        tailTimer = t
    }

    private func stopTailTimer() {
        tailTimer?.invalidate()
        tailTimer = nil
    }

    private func reloadLog() {
        reloadTask?.cancel()
        let url = logURL
        reloadTask = Task { [weak self] in
            if let client = UsageUIClient.current {
                guard let text = try? await client.value("usage.ui.log", as: String.self),
                    !Task.isCancelled
                else { return }
                self?.log = text
                return
            }
            let text = await Task.detached(priority: .utility) {
                FileTail.read(url, maxBytes: 64 * 1024)
            }.value
            guard !Task.isCancelled else { return }
            guard let self, text != self.log else { return }
            self.log = text
        }
    }
}
