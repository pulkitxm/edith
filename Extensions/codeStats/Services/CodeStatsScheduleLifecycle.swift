import Foundation

@MainActor final class CodeStatsScheduleLifecycle {
    static let jobID = "codestats.schedule"
    private let interval: @MainActor () -> TimeInterval?
    private let ready: @MainActor () async -> Void
    private let check: @MainActor () async -> Void
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async throws -> Void
    private var loop: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var lastCompleted: Date?
    private var started = false
    private var stopped = false

    init(
        interval: @escaping @MainActor () -> TimeInterval? = { 600 },
        ready: @escaping @MainActor () async -> Void = {},
        check: @escaping @MainActor () async -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.interval = interval; self.ready = ready; self.check = check
        self.now = now; self.sleep = sleep
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        reschedule()
    }

    func reschedule() {
        guard started, !stopped else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self else { return }
            await self.ready()
            while !Task.isCancelled {
                guard !self.stopped, let interval = self.interval(), interval.isFinite, interval > 0
                else { return }
                let delay =
                    self.lastCompleted.map {
                        max(0, interval - self.now().timeIntervalSince($0))
                    } ?? 0
                if delay > 0 {
                    do { try await self.sleep(.seconds(delay)) } catch { return }
                    continue
                }
                await self.runExplicit()
            }
        }
    }

    func runExplicit() async {
        guard !stopped else { return }
        if let pending { await pending.value; return }
        let pending = Task { [weak self] in
            guard let self, !self.stopped else { return }
            await self.check()
            self.lastCompleted = self.now()
        }
        self.pending = pending
        await pending.value
        if self.pending == pending { self.pending = nil }
    }

    func cancel() {
        stopped = true; started = false
        loop?.cancel(); pending?.cancel()
    }

    func shutdown() async {
        cancel()
        let loop = loop; let pending = pending
        self.loop = nil; self.pending = nil
        await loop?.value
        await pending?.value
    }
}
