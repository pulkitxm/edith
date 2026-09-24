import AppKit

@MainActor
final class ApprovalStatusRefresher {
    private static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]

    private let refresh: @MainActor () -> Void
    private var attempt = 0
    private var pending: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?

    init(refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
    }

    func update(awaitingApproval: Bool) {
        pending?.cancel()
        pending = nil
        guard awaitingApproval else {
            attempt = 0
            if let activationObserver {
                NotificationCenter.default.removeObserver(activationObserver)
            }
            activationObserver = nil
            return
        }
        observeActivation()
        let delay = Self.delays[min(attempt, Self.delays.count - 1)]
        attempt += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.attempt = 0
                self.refresh()
            }
        }
    }
}
