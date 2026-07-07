import Foundation

@MainActor
public final class DashboardRefreshBridge: ObservableObject {
    @Published public private(set) var updating = false
    @Published public private(set) var log = ""

    private var tokens: [NSObjectProtocol] = []
    private let logURL: URL

    public init(logURL: URL = Repo.dataDir.appendingPathComponent("refresh.log")) {
        self.logURL = logURL
        tokens.append(
            IPC.observe(IPC.Name.usageRefreshStarted) { [weak self] in
                self?.updating = true
            })
        tokens.append(
            IPC.observe(IPC.Name.usageRefreshFinished) { [weak self] in
                self?.updating = false
                self?.reloadLog()
            })
        reloadLog()
    }

    deinit {
        for token in tokens { IPC.stopObserving(token) }
    }

    public func requestRefresh() {
        IPC.post(IPC.Name.requestUsageRefresh)
    }

    private func reloadLog() {
        log = FileTail.read(logURL, maxBytes: 64 * 1024)
    }
}
