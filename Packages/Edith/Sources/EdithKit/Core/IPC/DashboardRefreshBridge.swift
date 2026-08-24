import Foundation
import Observation

@MainActor
@Observable
public final class DashboardRefreshBridge {
    public private(set) var updating = false
    public private(set) var log = ""

    @ObservationIgnored private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []
    private let logURL: URL
    private let requestUsageRefresh: () -> Void
    @ObservationIgnored private nonisolated(unsafe) var tailTimer: Timer?

    public init(
        logURL: URL = Repo.dataDir.appendingPathComponent("refresh.log"),
        requestUsageRefresh: @escaping () -> Void = {
            UsageCollectionOperationExecution.request(.refresh)
        }
    ) {
        self.logURL = logURL
        self.requestUsageRefresh = requestUsageRefresh
        tokens.append(
            IPC.observe(IPC.Name.usageRefreshStarted) { [weak self] in
                self?.beginTail()
            })
        tokens.append(
            IPC.observe(IPC.Name.usageRefreshFinished) { [weak self] in
                self?.endTail()
            })
        reloadLog()
    }

    deinit {
        tailTimer?.invalidate()
        for token in tokens { IPC.stopObserving(token) }
    }

    public func requestRefresh() {
        requestUsageRefresh()
    }

    private func beginTail() {
        updating = true
        reloadLog()
        tailTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadLog() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        tailTimer = t
    }

    private func endTail() {
        tailTimer?.invalidate()
        tailTimer = nil
        updating = false
        reloadLog()
    }

    private func reloadLog() {
        log = FileTail.read(logURL, maxBytes: 64 * 1024)
    }
}
