import Foundation

@MainActor final class HerdrDiscoveryAdmission {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let timer: Task<Void, Never>?
    }
    private let interval: @MainActor () -> TimeInterval?
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleep: Sleep
    private var lastAdmissions: [String: ContinuousClock.Instant] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private(set) var stopped = false
    var pendingCount: Int { waiters.count }
    var timerCount: Int { timers.count }

    init(
        interval: @escaping @MainActor () -> TimeInterval?,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    func admit(_ key: String) async -> Bool {
        while !stopped, !Task.isCancelled {
            let cadence = interval()
            if let cadence {
                guard cadence.isFinite, cadence > 0 else { return false }
                if let last = lastAdmissions[key] {
                    let remaining = now().duration(to: last + .seconds(cadence))
                    if remaining > .zero {
                        await wait(remaining)
                        continue
                    }
                }
                guard !stopped, !Task.isCancelled else { return false }
                lastAdmissions[key] = now()
                return true
            }
            await wait(nil)
        }
        return false
    }

    func retire(_ key: String) { lastAdmissions[key] = nil }

    func refresh() {
        let current = waiters
        waiters.removeAll()
        for waiter in current.values {
            waiter.timer?.cancel()
            waiter.continuation.resume()
        }
    }

    func stop() {
        stopped = true
        lastAdmissions.removeAll()
        refresh()
    }

    func stopAndWait() async {
        stop()
        let current = Array(timers.values)
        for timer in current { await timer.value }
    }

    private func wait(_ duration: Duration?) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !stopped, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                let timer = duration.map { duration in
                    Task { [weak self, sleep] in
                        defer { self?.timers[id] = nil }
                        do { try await sleep(duration) } catch { return }
                        self?.wake(id)
                    }
                }
                timers[id] = timer
                waiters[id] = Waiter(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume()
    }
}

@MainActor enum HerdrTrackingDemand {
    static func read(
        activeVersion: @escaping @MainActor () -> String?,
        invoke: @escaping @MainActor (String, Data) async throws -> Data
    ) async -> Bool {
        guard let version = activeVersion(), !version.isEmpty, version.utf8.count <= 128 else {
            return false
        }
        do {
            let data = try await invoke("attention.settings.get", Data("{}".utf8))
            guard !Task.isCancelled, activeVersion() == version, data.count <= 1_048_576 else {
                return false
            }
            struct Settings: Decodable { let isEnabled: Bool; let agentTrackingEnabled: Bool }
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            return settings.isEnabled && settings.agentTrackingEnabled
        } catch { return false }
    }
}
