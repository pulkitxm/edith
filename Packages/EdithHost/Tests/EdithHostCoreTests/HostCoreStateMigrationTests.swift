import Darwin
import Foundation
import SQLite3
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostCoreStateMigrationTests {
    private let migrations = [
        "0001-foundations", "0002-companion-health", "0003-agent-events",
        "0004-attention-delivery-receipts", "0005-attention-event-kind", "0006-scheduled-tasks",
    ]

    private func fixture(_ body: (HostIdentity) async throws -> Void) async throws {
        let support = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("core-state-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let identity = try HostIdentity(identifier: "com.pulkit.edith", supportDirectory: support)
        try FileManager.default.createDirectory(
            at: identity.root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try await body(identity)
    }

    private func database(_ identity: HostIdentity, wal: Bool = false) throws -> OpaquePointer {
        var database: OpaquePointer?
        #expect(
            sqlite3_open(identity.root.appendingPathComponent("edith.sqlite").path, &database)
                == SQLITE_OK)
        let handle = try #require(database)
        if wal { try execute(handle, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0") }
        try execute(
            handle,
            """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            CREATE TABLE scheduled_task (
                id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, definition BLOB NOT NULL,
                enabled INTEGER NOT NULL, createdAt TEXT NOT NULL, nextRunAt TEXT,
                lastRunAt TEXT, lastTaskID TEXT);
            CREATE TABLE agent_event (sequence INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL);
            """)
        for migration in migrations {
            try execute(handle, "INSERT INTO grdb_migrations VALUES ('\(migration)')")
        }
        return handle
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        guard sqlite3_errcode(database) == SQLITE_OK else { throw HostCoreStateMigration.invalid() }
    }

    private func insert(_ data: Data, database: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
        let handle = try #require(statement)
        defer { sqlite3_finalize(handle) }
        data.withUnsafeBytes {
            #expect(sqlite3_bind_blob(handle, 1, $0.baseAddress, Int32($0.count), nil) == SQLITE_OK)
            #expect(sqlite3_step(handle) == SQLITE_DONE)
        }
    }

    private func task(_ identity: HostIdentity, state: HostAgentTaskState = .succeeded) throws
        -> HostAgentTaskStatus
    {
        let status = HostAgentTaskStatus(
            snapshot: .init(
                id: UUID(), operation: "command.run", title: "Synthetic saved command",
                state: state,
                submittedAt: Date(), finishedAt: state.isTerminal ? Date() : nil),
            output: [.init(sequence: 1, stream: .standardOutput, text: "fixture output")],
            result: Data("fixture result".utf8))
        let directory = identity.root.appendingPathComponent("Tasks")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("\(status.snapshot.id.uuidString).json")
        let data = try HostAgentPayload.encode(
            PersistedHostAgentTask(fingerprint: "fixture", status: status))
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        return try HostAgentPayload.decode(PersistedHostAgentTask.self, from: data).status
    }

    @Test func importsOriginalJSONSQLAndWALWithoutChangingSourcesOrRunningCommands() async throws {
        try await fixture { identity in
            let completed = try task(identity)
            let interrupted = try task(identity, state: .running)
            let database = try database(identity, wal: true)
            defer { sqlite3_close(database) }
            let definition = try HostScheduledTaskDefinition(
                name: "saved-fixture", schedule: .interval(seconds: 600),
                executablePath: "/fixture/never-run",
                arguments: ["synthetic"], timeout: 20)
            let scheduleID = UUID()
            try insert(
                HostAgentPayload.encode(definition), database: database,
                sql: """
                    INSERT INTO scheduled_task VALUES ('\(scheduleID.uuidString)', 'saved-fixture', ?, 1,
                        '2026-10-10 17:00:00.123', '2200-01-01 00:00:00.123',
                        '2026-10-10 17:00:00.123', '\(completed.snapshot.id.uuidString)')
                    """)
            let event = HostCoreAgentEvent(
                category: "task", name: "saved.event", message: "fixture history")
            try insert(
                HostAgentPayload.encode(event), database: database,
                sql: "INSERT INTO agent_event(payload) VALUES (?)")
            let sourcePaths = [
                "edith.sqlite", "edith.sqlite-wal", "edith.sqlite-shm",
                "Tasks/\(completed.snapshot.id.uuidString).json",
                "Tasks/\(interrupted.snapshot.id.uuidString).json",
            ]
            let before = try sourcePaths.map {
                try Data(contentsOf: identity.root.appendingPathComponent($0))
            }
            try HostCoreStateMigration.importExisting(identity: identity)
            let after = try sourcePaths.map {
                try Data(contentsOf: identity.root.appendingPathComponent($0))
            }
            #expect(before == after)
            let commands = try HostAgentCommandService(
                directory: identity.root.appendingPathComponent("Core/Commands"),
                environment: { [:] })
            #expect(try await commands.tasks.status(completed.snapshot.id) == completed)
            let restored = try await commands.tasks.status(interrupted.snapshot.id)
            #expect(restored.snapshot.state == .interrupted)
            #expect(restored.output == interrupted.output)
            #expect(restored.result == interrupted.result)
            let schedules = try await commands.schedules.list()
            #expect(schedules.count == 1)
            #expect(schedules.first?.id == scheduleID)
            #expect(schedules.first?.definition == definition)
            #expect(schedules.first?.lastTaskID == completed.snapshot.id)
            let expectedNext = Date(timeIntervalSince1970: 7_258_118_400.123)
            let expectedLast = Date(timeIntervalSince1970: 1_791_651_600.123)
            let nextRun = try #require(schedules.first?.nextRunAt)
            let lastRun = try #require(schedules.first?.lastRunAt)
            #expect(abs(nextRun.timeIntervalSince(expectedNext)) < 0.0001)
            #expect(abs(lastRun.timeIntervalSince(expectedLast)) < 0.0001)
            let journal = try HostAgentJournal(
                directory: identity.root.appendingPathComponent("Core"))
            let stored = try JSONDecoder().decode(
                HostCoreAgentStore.Journal.self,
                from: journal.read("agent.json", maximumBytes: 2_097_152))
            #expect(stored.events.map(\.id) == [event.id])
            await commands.shutdown()
            try HostCoreStateMigration.importExisting(identity: identity)
            #expect(
                before
                    == (try sourcePaths.map {
                        try Data(contentsOf: identity.root.appendingPathComponent($0))
                    }))
            #expect(
                try FileManager.default.contentsOfDirectory(
                    atPath: identity.root.appendingPathComponent("Core").path
                )
                .allSatisfy { !$0.hasPrefix(".state-import-") })
        }
    }

    @Test func existingDestinationsWinAndReceiptPreventsReimportAfterRemoval() async throws {
        try await fixture { identity in
            let original = try task(identity)
            let commands = try HostAgentCommandService(
                directory: identity.root.appendingPathComponent("Core/Commands"),
                environment: { [:] })
            _ = try await commands.tasks.cancel(original.snapshot.id)
            let schedules = try HostAgentJournal(
                directory: identity.root.appendingPathComponent("Core/Commands/Schedules"))
            try schedules.write(Data("[]".utf8), name: "schedules.json", maximumBytes: 32)
            try HostCoreStateMigration.importExisting(identity: identity)
            let reopened = try HostAgentCommandService(
                directory: identity.root.appendingPathComponent("Core/Commands"),
                environment: { [:] })
            #expect(
                try await reopened.tasks.status(original.snapshot.id).snapshot.state == .cancelled)
            let tasks = try HostAgentJournal(
                directory: identity.root.appendingPathComponent("Core/Commands/Tasks"))
            try tasks.remove("\(original.snapshot.id.uuidString).json")
            try HostCoreStateMigration.importExisting(identity: identity)
            #expect(try tasks.files().isEmpty)
            await commands.shutdown()
            await reopened.shutdown()
        }
    }

    @Test func newerSchemaMalformedPayloadAndSymlinkFailBeforePublishingReceipt() async throws {
        for scenario in 0..<4 {
            try await fixture { identity in
                if scenario != 2 {
                    let database = try database(identity)
                    defer { sqlite3_close(database) }
                    if scenario == 0 {
                        try execute(database, "INSERT INTO grdb_migrations VALUES ('0007-future')")
                    } else if scenario == 1 {
                        try insert(
                            Data("{}".utf8), database: database,
                            sql: "INSERT INTO agent_event(payload) VALUES (?)")
                    } else {
                        try execute(database, "PRAGMA user_version=7")
                    }
                    #expect(throws: (any Error).self) {
                        try HostCoreStateMigration.importExisting(identity: identity)
                    }
                } else {
                    let status = try task(identity)
                    let file = identity.root.appendingPathComponent(
                        "Tasks/\(status.snapshot.id.uuidString).json")
                    let renamed = file.appendingPathExtension("original")
                    try FileManager.default.moveItem(at: file, to: renamed)
                    try FileManager.default.createSymbolicLink(
                        at: file, withDestinationURL: renamed)
                    #expect(throws: HostAgentCommandError.self) {
                        try HostCoreStateMigration.importExisting(identity: identity)
                    }
                }
                #expect(
                    !FileManager.default.fileExists(
                        atPath: identity.root.appendingPathComponent("Core/state-import.json").path)
                )
                #expect(
                    !FileManager.default.fileExists(
                        atPath: identity.root.appendingPathComponent("Core/agent.json").path))
            }
        }
    }

    @Test func legacyImportReservesCurrentTaskCapacity() async throws {
        try await fixture { identity in
            _ = try task(identity)
            _ = try task(identity)
            let journal = try HostAgentJournal(
                directory: identity.root.appendingPathComponent("Core/Commands/Tasks"))
            var current: Set<UUID> = []
            for _ in 0..<99 {
                let id = UUID()
                current.insert(id)
                let status = HostAgentTaskStatus(
                    snapshot: .init(
                        id: id, operation: "command.run", title: "Current fixture history",
                        state: .succeeded, submittedAt: Date(), finishedAt: Date()),
                    result: Data(count: 1024))
                try journal.write(
                    HostAgentPayload.encode(
                        PersistedHostAgentTask(fingerprint: nil, status: status)),
                    name: "\(id.uuidString).json", maximumBytes: 17 << 20)
            }
            try HostCoreStateMigration.importExisting(identity: identity)
            let restored = try HostAgentTaskService(directory: journal.directory)
            let identities = Set(await restored.snapshots().map(\.id))
            #expect(identities.count == 100)
            #expect(current.isSubset(of: identities))
            #expect(try journal.files().count == 100)
            await restored.shutdown()
        }
    }

    @Test func legacyImportReservesCurrentResultBudget() async throws {
        try await fixture { identity in
            let original = try task(identity)
            let journal = try HostAgentJournal(
                directory: identity.root.appendingPathComponent("Core/Commands/Tasks"))
            var current: Set<UUID> = []
            for _ in 0..<2 {
                let id = UUID()
                current.insert(id)
                let status = HostAgentTaskStatus(
                    snapshot: .init(
                        id: id, operation: "command.run", title: "Current fixture result",
                        state: .succeeded, submittedAt: Date(), finishedAt: Date()),
                    result: Data(count: 8 << 20))
                try journal.write(
                    HostAgentPayload.encode(
                        PersistedHostAgentTask(fingerprint: nil, status: status)),
                    name: "\(id.uuidString).json", maximumBytes: 17 << 20)
            }
            try HostCoreStateMigration.importExisting(identity: identity)
            let restored = try HostAgentTaskService(directory: journal.directory)
            #expect(Set(await restored.snapshots().map(\.id)) == current)
            #expect(!current.contains(original.snapshot.id))
            #expect(try journal.files().count == 2)
            await restored.shutdown()
        }
    }

    @Test func changedOrLinkedSourceIsRefusedWithoutChangingOriginalContents() async throws {
        try await fixture { identity in
            let status = try task(identity)
            let directory = identity.root.appendingPathComponent("Tasks")
            let name = "\(status.snapshot.id.uuidString).json"
            let source = try #require(try HostCoreStateSource(directory: directory))
            let copy = identity.root.appendingPathComponent("owned-copy.json")
            let before = try Data(contentsOf: directory.appendingPathComponent(name))
            let metadata = try source.copy(name, to: copy, maximumBytes: 17 << 20)
            #expect(try Data(contentsOf: copy) == before)
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == before)
            let changed = before + Data(" ".utf8)
            try changed.write(to: directory.appendingPathComponent(name))
            #expect(throws: HostAgentCommandError.self) {
                try source.validate(metadata, name: name)
            }
            let alias = directory.appendingPathComponent("linked.json")
            #expect(link(directory.appendingPathComponent(name).path, alias.path) == 0)
            #expect(throws: HostAgentCommandError.self) {
                try source.read(name, maximumBytes: 17 << 20)
            }
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == changed)
        }
    }

    @Test func developmentIdentityNeverReadsProductionShapedSources() async throws {
        try await fixture { production in
            let development = try HostIdentity(
                identifier: "com.pulkit.edith.tests.owned", supportDirectory: production.root)
            try FileManager.default.createDirectory(
                at: development.root, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: development.root.appendingPathComponent("edith.sqlite"),
                withDestinationURL: production.root)
            try HostCoreStateMigration.importExisting(identity: development)
            #expect(
                !FileManager.default.fileExists(
                    atPath: development.root.appendingPathComponent("Core").path))
        }
    }

    @Test func replacedSourceDirectoryCannotContinueAnAdmittedImport() async throws {
        try await fixture { identity in
            let status = try task(identity)
            let directory = identity.root.appendingPathComponent("Tasks")
            let source = try #require(try HostCoreStateSource(directory: directory))
            let name = "\(status.snapshot.id.uuidString).json"
            let original = try source.read(name, maximumBytes: 17 << 20)
            let moved = identity.root.appendingPathComponent("Tasks-original")
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            #expect(throws: HostAgentCommandError.self) {
                try source.read(name, maximumBytes: 17 << 20)
            }
            #expect(throws: HostAgentCommandError.self) { try source.names() }
            #expect(try Data(contentsOf: moved.appendingPathComponent(name)) == original)
        }
    }
}
