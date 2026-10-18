import Darwin
import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageRemoteCollectionTests {
    @Test func savedMachinesUseTheAuthoritativeISO8601RegistrySchema() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("machines.json")
        let machine = Machine(
            name: "Synthetic remote", host: "builder.invalid", port: 2222,
            username: "test", createdAt: Date(timeIntervalSince1970: 1_791_504_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([machine]).write(to: file)
        #expect(MachineRegistry.machines(file: file) == [machine])
        try JSONEncoder().encode([machine]).write(to: file)
        #expect(MachineRegistry.machines(file: file).isEmpty)
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target.json")
        try encoder.encode([machine]).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(MachineRegistry.machines(file: file).isEmpty)
    }

    @Test func remoteProjectPathsAcceptOnlyAbsoluteASCIIWindowsDrives() throws {
        for path in [
            "C:/workspace/project", "z:\\workspace\\project", "C:/", "Z:\\", "/remote/project",
        ] {
            try UsageRemoteProjectMetadata(
                cwd: path, root: path, repositoryID: "sample", repositoryName: "Sample",
                folderName: "sample"
            ).validate()
        }
        for path in [
            "1:\\project", "é:\\project", "_: /project", "C:project", "C:", "CC:/project",
            "relative/project", "\\project",
        ] {
            #expect(throws: UsageNativeFailure.self) {
                try UsageRemoteProjectMetadata(
                    cwd: path, root: path, repositoryID: "sample", repositoryName: "Sample",
                    folderName: "sample"
                ).validate()
            }
        }
    }

    @Test func remoteProjectsNeverResolveAnIdenticalLocalWorkingDirectory() async throws {
        let fixture = temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let localProject = fixture.appendingPathComponent("local/project")
        try FileManager.default.createDirectory(
            at: localProject.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n url=https://github.com/example/local-private.git\n".utf8)
            .write(
                to: localProject.appendingPathComponent(".git/config"))
        let home = fixture.appendingPathComponent("snapshot-one/home")
        try journal(home: home, cwd: localProject.path)
        let metadata = UsageRemoteProjectMetadata(
            cwd: localProject.path, root: localProject.path,
            repositoryID: "github.com/example/remote", repositoryName: "Remote project",
            repositoryURL: "https://github.com/example/remote", folderName: "project")
        let machineID = UUID()
        let context = UsageRemoteCollectionContext(
            machineID: machineID, projects: [metadata], timeZone: "UTC")
        let data = try await collect(
            home, archive: fixture.appendingPathComponent("archive"), context: context)
        let project = try #require(projects(data).first)
        #expect(project["repositoryID"] as? String == metadata.repositoryID)
        #expect(project["path"] as? String == localProject.path)
        #expect(!String(decoding: data, as: UTF8.self).contains("local-private"))
        let missing = try await collect(
            home, archive: fixture.appendingPathComponent("empty-archive"),
            context: .init(machineID: machineID, timeZone: "UTC"))
        #expect(
            try projects(missing).first?["repositoryID"] as? String == "folder:" + localProject.path
        )
        #expect(!String(decoding: missing, as: UTF8.self).contains("local-private"))
    }

    @Test func twoEphemeralHomesKeepAnonymousReceiptIdentityAndHistoricalMetadata() async throws {
        let fixture = temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let archive = fixture.appendingPathComponent("archive")
        let machineID = UUID()
        let metadata = UsageRemoteProjectMetadata(
            cwd: "/remote/projects/sample", root: "/remote/projects/sample",
            repositoryID: "github.com/example/sample", repositoryName: "Sample",
            repositoryURL: "https://github.com/example/sample", folderName: "sample",
            worktree: "topic")
        let homeOne = fixture.appendingPathComponent("snapshot-one/home")
        try journal(home: homeOne, cwd: metadata.cwd)
        let first = try await collect(
            homeOne, archive: archive,
            context: .init(machineID: machineID, projects: [metadata], timeZone: "UTC"))
        try FileManager.default.removeItem(at: homeOne)
        let homeTwo = fixture.appendingPathComponent("snapshot-two/home")
        try journal(home: homeTwo, cwd: metadata.cwd)
        let second = try await collect(
            homeTwo, archive: archive,
            context: .init(machineID: machineID, timeZone: "UTC"))
        #expect(try tokens(first) == 12)
        #expect(try tokens(second) == 12)
        let stored = try UsageNativeArchive(
            dataDirectory: archive,
            remoteContext: .init(machineID: machineID))
        #expect(
            try stored.database.rows("SELECT COUNT(*) AS count FROM files").first?["count"] == "1")
        #expect(try stored.events().count == 1)
        #expect(try projects(second).first?["repositoryID"] as? String == metadata.repositoryID)
        #expect(try projects(second).first?["path"] as? String == metadata.root)
        try FileManager.default.removeItem(at: homeTwo)
        let homeThree = fixture.appendingPathComponent("snapshot-three/home")
        try FileManager.default.createDirectory(
            at: homeThree, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let retained = try await collect(
            homeThree, archive: archive,
            context: .init(machineID: machineID, timeZone: "UTC"))
        #expect(try tokens(retained) == 12)
        #expect(try projects(retained).first?["repositoryID"] as? String == metadata.repositoryID)
        #expect(try projects(retained).first?["worktrees"] as? [[String: Any]] != nil)
    }

    @Test func archiveOwnershipAndRemoteMetadataAreValidatedBeforeCollection() async throws {
        let fixture = temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        try journal(home: home, cwd: "/remote/projects/sample")
        let archive = fixture.appendingPathComponent("archive")
        let id = UUID()
        _ = try await collect(home, archive: archive, context: .init(machineID: id))
        await #expect(throws: UsageNativeFailure.self) {
            _ = try await collect(home, archive: archive, context: .init(machineID: UUID()))
        }
        await #expect(throws: UsageNativeFailure.self) {
            _ = try await UsageNativeCollector.collect(
                home: home, dataDirectory: archive,
                environment: ["EDITH_USAGE_OFFLINE": "1"], onEvent: { _ in })
        }
        let project = UsageRemoteProjectMetadata(
            cwd: "/remote/sample", root: "/remote/sample",
            repositoryID: "sample", repositoryName: "Sample", folderName: "sample")
        #expect(throws: UsageNativeFailure.self) {
            try UsageRemoteCollectionContext(machineID: id, projects: [project, project]).validate()
        }
        #expect(throws: UsageNativeFailure.self) {
            try UsageRemoteCollectionContext(machineID: id, timeZone: "invalid/time-zone")
                .validate()
        }
        let invalid = UsageRemoteProjectMetadata(
            cwd: "/remote/sample", root: "/remote/sample",
            repositoryID: "sample", repositoryName: "Sample",
            repositoryURL: "https://secret@example.com/sample", folderName: "sample")
        #expect(throws: UsageNativeFailure.self) { try invalid.validate() }
        #expect(throws: UsageNativeFailure.self) {
            try UsageRemoteCollectionContext(machineID: id).journalKey(
                source: "cli",
                file: fixture.appendingPathComponent("outside.jsonl"), home: home)
        }
    }

    @Test func snapshotsRejectDirectoryLinksSpecialFilesCredentialsAndOversizedInputs() async throws
    {
        let fixture = temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let context = UsageRemoteCollectionContext(machineID: UUID())
        let home = fixture.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outside = fixture.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let link = home.appendingPathComponent(".codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        await #expect(throws: UsageNativeFailure.self) {
            _ = try await collect(
                home, archive: fixture.appendingPathComponent("archive"), context: context)
        }
        #expect(
            !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("archive").path))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let credentials = link.appendingPathComponent("auth.json")
        try Data("INVALID_CREDENTIAL_CANARY".utf8).write(to: credentials)
        #expect(throws: UsageNativeFailure.self) { try context.validateStagedHome(home) }
        try FileManager.default.removeItem(at: credentials)
        let pipe = home.appendingPathComponent("source-pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: UsageNativeFailure.self) { try context.validateStagedHome(home) }
        try FileManager.default.removeItem(at: pipe)
        let oversized = home.appendingPathComponent("oversized.jsonl")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 134_217_729); try handle.close()
        #expect(throws: UsageNativeFailure.self) { try context.validateStagedHome(home) }
    }

    @Test func databaseReceiptKeysStayStableAcrossIndependentSnapshotLocations() async throws {
        let fixture = temporary()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let archive = fixture.appendingPathComponent("archive")
        let context = UsageRemoteCollectionContext(machineID: UUID(), timeZone: "UTC")
        for name in ["snapshot-one", "snapshot-two"] {
            let home = fixture.appendingPathComponent(name + "/home")
            try UsageNativeFileIO.privateDirectory(home)
            let directory = home.appendingPathComponent(".local/share/opencode")
            try UsageNativeFileIO.privateDirectory(directory)
            let database = try UsageNativeDatabase(
                url: directory.appendingPathComponent("opencode.db"))
            try database.execute(
                "CREATE TABLE session(id TEXT PRIMARY KEY,directory TEXT,title TEXT); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,data TEXT)"
            )
            try database.run(
                "INSERT INTO session VALUES(?,?,?)", ["sample", "/remote/sample", "Sample"])
            let row: [String: Any] = [
                "id": "sample", "sessionID": "sample", "role": "assistant", "modelID": "gpt-5",
                "path": ["cwd": "/remote/sample"], "time": ["created": 1_791_504_000_000],
                "cost": 1,
                "tokens": ["input": 10, "output": 2, "cache": ["read": 0, "write": 0]],
            ]
            try database.run(
                "INSERT INTO message VALUES(?,?,?)",
                ["sample", "sample", String(decoding: UsageNativeJSON.encode(row), as: UTF8.self)])
            database.close()
            let data = try await collect(home, archive: archive, context: context)
            #expect(try tokens(data) == 12)
            try FileManager.default.removeItem(at: home)
        }
        let stored = try UsageNativeArchive(dataDirectory: archive, remoteContext: context)
        #expect(
            try stored.database.rows("SELECT COUNT(DISTINCT path) AS count FROM records").first?[
                "count"] == "1")
        #expect(try stored.events().count == 1)
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func journal(home: URL, cwd: String) throws {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = home.appendingPathComponent(".claude/projects/sample/session.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-10-09T01:00:00Z", "cwd": cwd, "sessionId": "sample", "costUSD": 1,
            "message": [
                "model": "claude-sonnet-4-5", "usage": ["input_tokens": 10, "output_tokens": 2],
            ],
        ])
        data.append(10); try data.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: file.path
        )
    }

    private func collect(_ home: URL, archive: URL, context: UsageRemoteCollectionContext)
        async throws -> Data
    {
        try await UsageNativeCollector.collectRemote(
            home: home, dataDirectory: archive, context: context,
            now: Date(timeIntervalSince1970: 1_791_504_000), onEvent: { _ in })
    }

    private func projects(_ data: Data) throws -> [[String: Any]] {
        let object = try UsageNativeJSON.object(data)
        return (object["daily"] as? [[String: Any]] ?? []).flatMap {
            $0["projects"] as? [[String: Any]] ?? []
        }
    }

    private func tokens(_ data: Data) throws -> Double {
        (try UsageNativeJSON.object(data)["totals"] as? [String: Any])?["tokens"] as? Double ?? 0
    }
}
