import Foundation

@MainActor public final class HostSettingsScheduler {
    private let signature: @MainActor () throws -> Data
    private let enabled: @MainActor () -> Bool
    private let onBattery: @MainActor () -> Bool
    private let run: @MainActor () async throws -> Bool
    private let now: @MainActor () -> Date
    private let delay: @Sendable (Duration) async throws -> Void
    private var previous: Data?
    private var completedAt: Date?
    private var polling: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var flight: Task<Bool, Error>?
    private var stopping = false

    public init(
        signature: @escaping @MainActor () throws -> Data,
        enabled: @escaping @MainActor () -> Bool,
        onBattery: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() },
        delay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        run: @escaping @MainActor () async throws -> Bool
    ) {
        self.signature = signature; self.enabled = enabled; self.onBattery = onBattery
        self.now = now; self.delay = delay; self.run = run
    }

    public func start() {
        guard !stopping, polling == nil else { return }
        preferencesChanged()
        polling = Task { [weak self, delay] in
            while !Task.isCancelled {
                do { try await delay(.seconds(60)) } catch { return }
                guard let self else { return }
                await self.runIfNeeded()
            }
        }
    }

    public func preferencesChanged() {
        guard !stopping else { return }
        debounce?.cancel()
        if !enabled() { flight?.cancel(); return }
        debounce = Task { [weak self, delay] in
            do { try await delay(.seconds(2)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.runIfNeeded()
        }
    }

    public func runIfNeeded() async {
        guard !stopping, flight == nil, enabled(), !onBattery(),
            let current = try? signature(),
            previous != current
                || completedAt.map({ now().timeIntervalSince($0) >= 86400 }) != false
        else { return }
        let task = Task {
            try Task.checkCancellation(); return try await run()
        }
        flight = task
        defer { flight = nil }
        do {
            if try await task.value, !stopping, !task.isCancelled {
                previous = current; completedAt = now()
            }
        } catch {}
    }

    public func shutdown() async {
        stopping = true
        polling?.cancel(); debounce?.cancel(); flight?.cancel()
        await polling?.value; await debounce?.value; _ = try? await flight?.value
        polling = nil; debounce = nil; flight = nil
    }
}
