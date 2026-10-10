import EdithExtensionUI
import EdithExtensionSupport
import Foundation

@MainActor
final class CompanionMonitor {
    static let jobID = "companion.health"

    private let job: CompanionHealthJob
    private let delivery: CompanionOutboxDelivery
    private let interval: @MainActor () -> TimeInterval?
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async throws -> Void
    private var lastCompleted: Date?
    private var periodic: Task<Void, Never>?
    private var started = false
    private(set) var latest: CompanionHealthSnapshot?
    private var loop: Task<Void, Never>?
    private var pending: Task<CompanionHealthSnapshot, Never>?
    private(set) var isStopped = false

    init(
        job: CompanionHealthJob = .init(), delivery: CompanionOutboxDelivery = .shared,
        interval: @escaping @MainActor () -> TimeInterval? = { 60 },
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.job = job; self.delivery = delivery
        self.interval = interval; self.now = now; self.sleep = sleep
    }

    var isRunning: Bool { loop != nil }

    func start() {
        guard !started, !isStopped else { return }
        started = true
        reschedule()
    }

    func reschedule() {
        guard started, !isStopped else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self, !self.isStopped else { return }
            await self.delivery.resume()
            while !Task.isCancelled {
                guard !self.isStopped, let interval = self.interval(),
                    interval.isFinite, interval > 0
                else { return }
                let delay =
                    self.lastCompleted.map { max(0, interval - self.now().timeIntervalSince($0)) }
                    ?? 0
                if delay > 0 {
                    do { try await self.sleep(.seconds(delay)) } catch { return }
                    continue
                }
                if let periodic = self.periodic {
                    await periodic.value
                } else {
                    let periodic = Task { [weak self] in
                        guard let self else { return }
                        _ = await self.refresh()
                        self.lastCompleted = self.now()
                    }
                    self.periodic = periodic
                    await periodic.value
                    if self.periodic == periodic { self.periodic = nil }
                }
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
        isStopped = true; started = false
        let loop = loop; self.loop = nil; loop?.cancel()
        let periodic = periodic; self.periodic = nil; periodic?.cancel()
        let pending = pending
        pending?.cancel(); self.pending = nil
        _ = await pending?.value
        await periodic?.value
        await loop?.value
        await delivery.cancel()
    }
}
