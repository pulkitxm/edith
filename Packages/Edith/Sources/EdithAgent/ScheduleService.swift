import EdithKit
import Foundation
import GRDB

public actor ScheduleService {
    public static let maximumSchedules = 64
    private static let longestSleep: TimeInterval = 3_600
    private static let idleSleep: TimeInterval = 86_400

    private struct Entry: Sendable {
        let id: UUID
        let definition: ScheduledTaskDefinition
        var enabled: Bool
        var nextRunAt: Date?
        var lastRunAt: Date?
        var lastTaskID: UUID?

        init(id: UUID, definition: ScheduledTaskDefinition, enabled: Bool, nextRunAt: Date?) {
            self.id = id
            self.definition = definition
            self.enabled = enabled
            self.nextRunAt = nextRunAt
        }

        init?(row: Row) {
            guard let id = UUID(uuidString: row["id"]),
                let definition = try? AgentPayload.decode(
                    ScheduledTaskDefinition.self, from: row["definition"])
            else { return nil }
            self.id = id
            self.definition = definition
            enabled = row["enabled"]
            nextRunAt = row["nextRunAt"]
            lastRunAt = row["lastRunAt"]
            lastTaskID = (row["lastTaskID"] as String?).flatMap(UUID.init(uuidString:))
        }
    }

    private let store: AgentStore
    private let tasks: AgentTaskService
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var loop: Task<Void, Never>?
    private var firing = false
    private var stopped = false

    public init(
        store: AgentStore, tasks: AgentTaskService,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.store = store
        self.tasks = tasks
        self.now = now
        self.calendar = calendar
        self.sleep = sleep
    }

    public func start() async {
        await skipMissedRuns()
        reschedule()
    }

    public func shutdown() {
        stopped = true
        loop?.cancel()
        loop = nil
    }

    public func add(_ definition: ScheduledTaskDefinition) async throws -> ScheduledTaskSnapshot {
        let existing = try await entries()
        guard existing.count < Self.maximumSchedules else {
            throw AgentError(
                .refused, "The agent keeps at most \(Self.maximumSchedules) schedules.")
        }
        guard !existing.contains(where: { $0.definition.name == definition.name }) else {
            throw AgentError(.refused, "A schedule named \(definition.name) already exists.")
        }
        guard let next = definition.schedule.next(after: now(), calendar: calendar) else {
            throw AgentError(.refused, "This schedule never runs.")
        }
        let entry = Entry(
            id: UUID(), definition: definition, enabled: true, nextRunAt: next)
        let encoded = try AgentPayload.encode(definition)
        let created = now()
        do {
            try await store.awaitWrite { database in
                try database.execute(
                    sql: """
                        INSERT INTO scheduled_task
                            (id, name, definition, enabled, createdAt, nextRunAt)
                        VALUES (?, ?, ?, 1, ?, ?)
                        """,
                    arguments: [entry.id.uuidString, definition.name, encoded, created, next])
            }
        } catch let error as DatabaseError
            where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
        {
            throw AgentError(.refused, "A schedule named \(definition.name) already exists.")
        }
        reschedule()
        return await snapshot(entry)
    }

    public func list() async throws -> [ScheduledTaskSnapshot] {
        var snapshots: [ScheduledTaskSnapshot] = []
        for entry in try await entries() { snapshots.append(await snapshot(entry)) }
        return snapshots
    }

    public func remove(_ name: String) async throws {
        let removed = try await store.awaitWrite { database in
            try database.execute(
                sql: "DELETE FROM scheduled_task WHERE name = ?", arguments: [name])
            return database.changesCount
        }
        guard removed > 0 else { throw Self.missing(name) }
        reschedule()
    }

    public func setEnabled(_ name: String, _ enabled: Bool) async throws -> ScheduledTaskSnapshot {
        var entry = try await entry(named: name)
        let next = enabled ? entry.definition.schedule.next(after: now(), calendar: calendar) : nil
        if enabled && next == nil { throw AgentError(.refused, "This schedule never runs.") }
        entry.enabled = enabled
        entry.nextRunAt = next
        let id = entry.id.uuidString
        try await store.awaitWrite { [entry] database in
            try database.execute(
                sql: "UPDATE scheduled_task SET enabled = ?, nextRunAt = ? WHERE id = ?",
                arguments: [entry.enabled, entry.nextRunAt, id])
        }
        reschedule()
        return await snapshot(entry)
    }

    public func runNow(_ name: String) async throws -> AgentTaskSnapshot {
        let entry = try await entry(named: name)
        guard !(await isRunning(entry.lastTaskID)) else {
            throw AgentError(.refused, "The previous run of \(name) has not finished.")
        }
        let launched = try await launch(entry.definition)
        try await record(launched, for: entry.id, nextRunAt: nil)
        return launched
    }

    public func fireDue() async {
        guard !firing, !stopped else { return }
        firing = true
        defer { firing = false }
        guard let all = try? await entries() else { return }
        let current = now()
        for entry in all where entry.enabled {
            guard let due = entry.nextRunAt, due <= current else { continue }
            let next = entry.definition.schedule.next(after: current, calendar: calendar)
            guard !(await isRunning(entry.lastTaskID)) else {
                try? await advance(entry.id, to: next)
                continue
            }
            do {
                let launched = try await launch(entry.definition)
                try await record(launched, for: entry.id, nextRunAt: next)
            } catch {
                AgentLog.logger.error(
                    "schedule \(entry.definition.name, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)"
                )
                try? await advance(entry.id, to: next)
            }
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await fireDue()
            let delay = await delayUntilNextRun()
            do { try await sleep(delay) } catch { return }
        }
    }

    private func reschedule() {
        loop?.cancel()
        guard !stopped else { return }
        loop = Task { await runLoop() }
    }

    private func delayUntilNextRun() async -> TimeInterval {
        guard let all = try? await entries() else { return Self.longestSleep }
        let upcoming = all.filter(\.enabled).compactMap(\.nextRunAt).min()
        guard let upcoming else { return Self.idleSleep }
        return min(max(upcoming.timeIntervalSince(now()), 1), Self.longestSleep)
    }

    private func skipMissedRuns() async {
        guard let all = try? await entries() else { return }
        let current = now()
        for entry in all where entry.enabled {
            guard entry.nextRunAt.map({ $0 <= current }) ?? true else { continue }
            try? await advance(
                entry.id, to: entry.definition.schedule.next(after: current, calendar: calendar))
        }
    }

    private func launch(_ definition: ScheduledTaskDefinition) async throws -> AgentTaskSnapshot {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: definition.executablePath),
            arguments: definition.arguments, environment: CLIToolEnvironment.sanitized(),
            currentDirectoryURL: URL(
                fileURLWithPath: definition.workingDirectory ?? NSHomeDirectory()),
            timeout: definition.timeout, maximumOutputBytes: 4 << 20,
            terminatesProcessGroup: true)
        return try await tasks.submit(
            AgentTaskSubmission(
                operation: AgentTaskOperation.command, title: "Schedule \(definition.name)",
                payload: AgentPayload.encode(request)))
    }

    private func isRunning(_ id: UUID?) async -> Bool {
        guard let id, let status = try? await tasks.status(id) else { return false }
        return !status.snapshot.state.isTerminal
    }

    private func record(_ launched: AgentTaskSnapshot, for id: UUID, nextRunAt: Date?) async throws
    {
        let started = now()
        let identifier = id.uuidString
        let taskID = launched.id.uuidString
        try await store.awaitWrite { database in
            try database.execute(
                sql: """
                    UPDATE scheduled_task
                    SET lastRunAt = ?, lastTaskID = ?, nextRunAt = COALESCE(?, nextRunAt)
                    WHERE id = ?
                    """,
                arguments: [started, taskID, nextRunAt, identifier])
        }
    }

    private func advance(_ id: UUID, to next: Date?) async throws {
        let identifier = id.uuidString
        try await store.awaitWrite { database in
            try database.execute(
                sql: "UPDATE scheduled_task SET nextRunAt = ? WHERE id = ?",
                arguments: [next, identifier])
        }
    }

    private func snapshot(_ entry: Entry) async -> ScheduledTaskSnapshot {
        var state: AgentTaskState?
        if let id = entry.lastTaskID, let status = try? await tasks.status(id) {
            state = status.snapshot.state
        }
        return ScheduledTaskSnapshot(
            id: entry.id, definition: entry.definition, enabled: entry.enabled,
            nextRunAt: entry.nextRunAt, lastRunAt: entry.lastRunAt, lastTaskID: entry.lastTaskID,
            lastState: state)
    }

    private func entries() async throws -> [Entry] {
        try await store.awaitRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, definition, enabled, nextRunAt, lastRunAt, lastTaskID
                    FROM scheduled_task ORDER BY name
                    """
            ).compactMap(Entry.init(row:))
        }
    }

    private func entry(named name: String) async throws -> Entry {
        guard let match = try await entries().first(where: { $0.definition.name == name }) else {
            throw Self.missing(name)
        }
        return match
    }

    private static func missing(_ name: String) -> AgentError {
        AgentError(.failed, "No schedule is named \(name).")
    }
}
