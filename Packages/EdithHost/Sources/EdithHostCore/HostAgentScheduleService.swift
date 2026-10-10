import EdithExtensionSupport
import Foundation

public actor HostAgentScheduleService {
    public static let maximumSchedules = 64
    public static let maximumJournalBytes = 4 << 20
    private struct Entry: Codable, Sendable {
        let id: UUID
        let definition: HostScheduledTaskDefinition
        var enabled: Bool
        var nextRunAt: Date?
        var lastRunAt: Date?
        var lastTaskID: UUID?
    }
    private let journal: HostAgentJournal
    private let tasks: HostAgentTaskService
    private let environment: @Sendable () -> [String: String]
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let record: @Sendable (HostAgentCommandEvent) async -> Void
    private var entries: [Entry]
    private var loop: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var firing = false
    private var stopped = false
    private var started = false
    private var launching: Set<UUID> = []

    public init(
        directory: URL, tasks: HostAgentTaskService,
        environment: @escaping @Sendable () -> [String: String],
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        record: @escaping @Sendable (HostAgentCommandEvent) async -> Void = { _ in }
    ) throws {
        journal = try HostAgentJournal(directory: directory)
        self.tasks = tasks; self.environment = environment; self.now = now
        self.calendar = calendar; self.sleep = sleep; self.record = record
        let files = try journal.files()
        if files.contains(where: { $0.lastPathComponent == "schedules.json" }) {
            entries = try HostAgentPayload.decode(
                [Entry].self,
                from: journal.read("schedules.json", maximumBytes: Self.maximumJournalBytes))
            guard entries.count <= Self.maximumSchedules,
                Set(entries.map(\.id)).count == entries.count,
                Set(entries.map(\.definition.name)).count == entries.count
            else { throw Self.invalid() }
            for entry in entries {
                try entry.definition.validate()
                guard entry.enabled || entry.nextRunAt == nil else { throw Self.invalid() }
            }
        } else {
            entries = []
        }
    }

    deinit { loop?.cancel() }

    public func start() async throws {
        guard !stopped, !started else { return }
        let current = now()
        var next = entries
        for index in next.indices
        where next[index].enabled && (next[index].nextRunAt.map { $0 <= current } ?? true) {
            next[index].nextRunAt = next[index].definition.schedule.next(
                after: current, calendar: calendar)
        }
        try save(next)
        started = true
        reschedule()
    }

    public func shutdown() async {
        stopped = true
        generation &+= 1
        let active = loop
        loop = nil
        active?.cancel()
        await active?.value
        while firing || !launching.isEmpty { await Task.yield() }
    }

    public func add(_ definition: HostScheduledTaskDefinition) async throws
        -> HostScheduledTaskSnapshot
    {
        try requireRunning()
        try definition.validate()
        guard entries.count < Self.maximumSchedules else {
            throw HostAgentCommandError(
                .refused, "The agent keeps at most \(Self.maximumSchedules) schedules.")
        }
        guard !entries.contains(where: { $0.definition.name == definition.name }) else {
            throw HostAgentCommandError(
                .refused, "A schedule named \(definition.name) already exists.")
        }
        guard let nextRun = definition.schedule.next(after: now(), calendar: calendar) else {
            throw Self.invalid()
        }
        let entry = Entry(id: UUID(), definition: definition, enabled: true, nextRunAt: nextRun)
        try save(entries + [entry])
        reschedule()
        return await snapshot(entry)
    }

    public func list() async throws -> [HostScheduledTaskSnapshot] {
        var values: [HostScheduledTaskSnapshot] = []
        for entry in entries.sorted(by: { $0.definition.name < $1.definition.name }) {
            values.append(await snapshot(entry))
        }
        return values
    }

    public func remove(_ name: String) throws {
        try requireRunning()
        let entry = try entry(named: name)
        try save(entries.filter { $0.id != entry.id })
        reschedule()
    }

    public func setEnabled(_ name: String, _ enabled: Bool) async throws
        -> HostScheduledTaskSnapshot
    {
        try requireRunning()
        var entry = try entry(named: name)
        entry.enabled = enabled
        entry.nextRunAt =
            enabled ? entry.definition.schedule.next(after: now(), calendar: calendar) : nil
        guard !enabled || entry.nextRunAt != nil else { throw Self.invalid() }
        try replace(entry)
        reschedule()
        return await snapshot(entry)
    }

    public func runNow(_ name: String) async throws -> HostAgentTaskSnapshot {
        try requireRunning()
        let entry = try entry(named: name)
        guard launching.insert(entry.id).inserted else { throw Self.overlap(name) }
        defer { launching.remove(entry.id) }
        guard !(await isRunning(entry.lastTaskID)) else { throw Self.overlap(name) }
        try requireRunning()
        guard entries.contains(where: { $0.id == entry.id }) else { throw Self.missing(name) }
        let launched = try await launch(entry.definition)
        try await finishLaunch(launched, for: entry.id, nextRunAt: nil)
        return launched
    }

    public func fireDue() async {
        guard !firing, !stopped else { return }
        firing = true
        defer { firing = false }
        let current = now()
        for original in entries
        where original.enabled && (original.nextRunAt.map { $0 <= current } ?? false) {
            guard !stopped, !Task.isCancelled else { return }
            guard launching.insert(original.id).inserted else { continue }
            defer { launching.remove(original.id) }
            let next = original.definition.schedule.next(after: current, calendar: calendar)
            do {
                let running = await isRunning(original.lastTaskID)
                guard !stopped, !Task.isCancelled,
                    let latest = entries.first(where: { $0.id == original.id }), latest.enabled,
                    latest.nextRunAt == original.nextRunAt
                else { continue }
                if running { try advance(original.id, to: next); continue }
                let launched = try await launch(original.definition)
                try await finishLaunch(launched, for: original.id, nextRunAt: next)
            } catch {
                try? advance(original.id, to: next)
                await record(
                    HostAgentCommandEvent(
                        level: .error, category: "schedule", name: "schedule.launch.failed",
                        message: error.localizedDescription))
            }
        }
    }

    private func runLoop(_ expected: UInt64) async {
        while !Task.isCancelled, !stopped, expected == generation {
            await fireDue()
            guard !Task.isCancelled, !stopped, expected == generation else { return }
            let upcoming = entries.filter(\.enabled).compactMap(\.nextRunAt).min()
            let delay = upcoming.map { min(max($0.timeIntervalSince(now()), 1), 3600) } ?? 86400
            do { try await sleep(delay) } catch { return }
        }
    }

    private func reschedule() {
        generation &+= 1
        loop?.cancel()
        guard !stopped, started else { return }
        let expected = generation
        loop = Task { await runLoop(expected) }
    }

    private func launch(_ definition: HostScheduledTaskDefinition) async throws
        -> HostAgentTaskSnapshot
    {
        do { try save(entries) } catch {
            stopped = true
            generation &+= 1
            loop?.cancel()
            throw error
        }
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: definition.executablePath),
            arguments: definition.arguments,
            environment: environment(),
            currentDirectoryURL: URL(
                fileURLWithPath: definition.workingDirectory ?? NSHomeDirectory()),
            timeout: definition.timeout, maximumOutputBytes: 2 << 20, terminatesProcessGroup: true)
        return try await tasks.submit(
            HostAgentTaskSubmission(
                operation: HostAgentTaskOperation.command, title: "Schedule \(definition.name)",
                payload: HostAgentPayload.encode(request)))
    }

    private func isRunning(_ id: UUID?) async -> Bool {
        guard let id, let status = try? await tasks.status(id) else { return false }
        return !status.snapshot.state.isTerminal
    }

    private func finishLaunch(_ launched: HostAgentTaskSnapshot, for id: UUID, nextRunAt: Date?)
        async throws
    {
        do { try recordLaunch(launched, for: id, nextRunAt: nextRunAt) } catch {
            stopped = true
            generation &+= 1
            loop?.cancel()
            _ = try? await tasks.cancelAndWait(launched.id)
            await record(
                HostAgentCommandEvent(
                    level: .error, category: "schedule", name: "schedule.persistence.failed",
                    message: error.localizedDescription, taskID: launched.id))
            throw error
        }
    }

    private func recordLaunch(_ launched: HostAgentTaskSnapshot, for id: UUID, nextRunAt: Date?)
        throws
    {
        guard var entry = entries.first(where: { $0.id == id }) else { return }
        entry.lastRunAt = now(); entry.lastTaskID = launched.id
        if let nextRunAt, entry.enabled { entry.nextRunAt = nextRunAt }
        try replace(entry)
    }

    private func advance(_ id: UUID, to next: Date?) throws {
        guard var entry = entries.first(where: { $0.id == id }) else { return }
        entry.nextRunAt = next
        try replace(entry)
    }

    private func snapshot(_ entry: Entry) async -> HostScheduledTaskSnapshot {
        var state: HostAgentTaskState?
        if let id = entry.lastTaskID { state = try? await tasks.status(id).snapshot.state }
        return HostScheduledTaskSnapshot(
            id: entry.id, definition: entry.definition, enabled: entry.enabled,
            nextRunAt: entry.nextRunAt,
            lastRunAt: entry.lastRunAt, lastTaskID: entry.lastTaskID, lastState: state)
    }

    private func save(_ next: [Entry]) throws {
        try journal.write(
            HostAgentPayload.encode(next), name: "schedules.json",
            maximumBytes: Self.maximumJournalBytes)
        entries = next
    }
    private func replace(_ entry: Entry) throws {
        try save(entries.map { $0.id == entry.id ? entry : $0 })
    }
    private func entry(named name: String) throws -> Entry {
        guard let entry = entries.first(where: { $0.definition.name == name }) else {
            throw Self.missing(name)
        }
        return entry
    }
    private func requireRunning() throws {
        guard !stopped else {
            throw HostAgentCommandError(.unavailable, "The agent is shutting down.")
        }
    }
    private static func missing(_ name: String) -> HostAgentCommandError {
        HostAgentCommandError(.failed, "No schedule is named \(name).")
    }
    private static func overlap(_ name: String) -> HostAgentCommandError {
        HostAgentCommandError(.refused, "The previous run of \(name) has not finished.")
    }
    private static func invalid() -> HostAgentCommandError {
        HostAgentCommandError(.refused, "The command schedule is invalid or never runs.")
    }
}
