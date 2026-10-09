import EdithExtensionUI
import EdithExtensionSupport
import Foundation

@MainActor
final class CompanionMonitor {
    nonisolated static let interval: Duration = .seconds(60)

    private let job: CompanionHealthJob
    private let delivery: CompanionOutboxDelivery
    private(set) var latest: CompanionHealthSnapshot?
    private var loop: Task<Void, Never>?
    private var pending: Task<CompanionHealthSnapshot, Never>?
    private(set) var isStopped = false

    init(job: CompanionHealthJob = .init(), delivery: CompanionOutboxDelivery = .shared) {
        self.job = job
        self.delivery = delivery
    }

    var isRunning: Bool { loop != nil }

    func start(interval: Duration = CompanionMonitor.interval) {
        guard loop == nil, !isStopped else { return }
        let delivery = delivery
        loop = Task { [weak self] in
            await delivery.resume()
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.refresh()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func refresh() async -> CompanionHealthSnapshot {
        if let pending { return await pending.value }
        guard !isStopped else { return latest ?? .unconfigured(at: Date()) }
        let job = job
        let task = Task.detached(priority: .utility) { await job.run() }
        pending = task
        let snapshot = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if pending == task { pending = nil }
        if !isStopped { latest = snapshot }
        return snapshot
    }

    func current() async -> CompanionHealthSnapshot {
        if let latest, Date().timeIntervalSince(latest.checkedAt) < 30 { return latest }
        return await refresh()
    }

    func stop() async {
        isStopped = true
        loop?.cancel(); loop = nil
        let pending = pending
        pending?.cancel(); self.pending = nil
        _ = await pending?.value
        await delivery.cancel()
    }
}
