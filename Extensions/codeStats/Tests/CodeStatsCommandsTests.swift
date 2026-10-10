import EdithExtensionSupport
import Foundation
import Testing
@testable import CodeStatsExtension

@Suite struct CodeStatsCommandsTests {
    @Test func reportsAndExportsUseOwnedSyntheticFacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let report = try JSONDecoder().decode(
            CodeStatsReport?.self, from: await fixture.call("codeStats.report", ["range": "30d"]))
        #expect(report?.totals.commits == 3)
        let filtered = try JSONDecoder().decode(
            CodeStatsReport?.self,
            from: await fixture.call(
                "codeStats.report", ["range": "90d", "filter": ["repositories": ["octo/site"]]]))
        #expect(filtered?.repositories.map(\.repository) == ["octo/site"])
        for card in ["highlights", "languages", "rhythm"] {
            var data = try await fixture.call("codeStats.export", ["range": "30d", "card": card])
            if let receipt = try? JSONDecoder().decode(CodeStatsCommands.Receipt.self, from: data) {
                data = Data()
                while data.count < receipt.byteCount {
                    let chunk = try JSONDecoder().decode(
                        CodeStatsCommands.Chunk.self,
                        from: await fixture.call(
                            "codeStats.result.chunk",
                            ["resultID": receipt.resultID.uuidString, "offset": data.count]))
                    #expect(chunk.offset == data.count)
                    #expect(chunk.data.count <= 262_144)
                    data.append(chunk.data)
                    #expect(chunk.finished == (data.count == receipt.byteCount))
                }
                #expect(data.count == receipt.byteCount)
                await #expect(throws: ExtensionPeerError.self) {
                    _ = try await fixture.call(
                        "codeStats.result.chunk",
                        ["resultID": receipt.resultID.uuidString, "offset": 0])
                }
            }
            let image = try JSONDecoder().decode(CodeStatsCommands.SharedImage.self, from: data)
            #expect(image.data.starts(with: [0x89, 0x50, 0x4e, 0x47]))
            #expect(image.filename == "edith-code-stats-\(card).png")
        }
        await fixture.commands.shutdown()
    }

    @Test func rejectsUnknownPathsInvalidQueriesAndUnconfirmedMutations() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalid: [(String, [String: Any])] = [
            ("codeStats.report", ["path": "/tmp/project"]),
            ("codeStats.report", ["range": "999999999999999999999999d"]),
            ("codeStats.report", ["range": "999999999999999999-01-01..999999999999999999-02-01"]),
            ("codeStats.report", ["range": "99999d"]),
            ("codeStats.report", ["filter": ["unknown": "x"]]),
            ("codeStats.folder", ["path": fixture.harness.mirror.path]),
            ("codeStats.schedule", ["kind": "daily", "hour": true]),
            ("codeStats.schedule", ["kind": "weekly", "weekday": 8]),
            ("codeStats.schedule", ["kind": "daily", "hour": 1.5]),
            ("codeStats.export", ["card": "highlights", "output": "/tmp/card.png"]),
            ("codeStats.result.chunk", ["resultID": UUID().uuidString, "offset": 0]),
            ("codeStats.identity.add", ["value": String(repeating: "x", count: 257)]),
        ]
        for (command, payload) in invalid {
            await #expect(throws: (any Error).self) { _ = try await fixture.call(command, payload) }
        }
        #expect(fixture.defaults.string(forKey: AppStorageKeys.CodeStats.folder) == nil)
        await fixture.commands.shutdown()
    }

    @Test func explicitSettingsAndIdentityCommandsPersistAndShutdownRejectsCalls() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try await fixture.call(
            "codeStats.schedule", ["kind": "weekly", "weekday": 6, "hour": 22])
        #expect(
            CodeStatsPreferences.schedule(in: fixture.defaults) == .weekly(weekday: 6, hour: 22))
        _ = try await fixture.call("codeStats.identity.add", ["value": "mock@example.invalid"])
        let identity = try JSONDecoder().decode(
            CodeStatsIdentity.self, from: await fixture.call("codeStats.identity.list", [:]))
        #expect(identity.emails == ["mock@example.invalid"])
        _ = try await fixture.call("codeStats.identity.remove", ["value": "mock@example.invalid"])
        #expect(CodeStatsPreferences.identity(in: fixture.defaults).isEmpty)
        _ = try await fixture.call(
            "codeStats.folder", ["path": fixture.harness.mirror.path, "confirm": true])
        #expect(
            CodeStatsPaths.selectedFolder(defaults: fixture.defaults) == fixture.harness.mirror.path
        )
        await fixture.commands.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await fixture.call("codeStats.status", [:])
        }
    }

    private struct Fixture {
        let harness: CodeStatsWorkflowHarness
        let defaults: UserDefaults
        let suite: String
        let commands: CodeStatsCommands
        init() throws {
            harness = try CodeStatsWorkflowHarness()
            suite = "test.edith.code-stats.commands.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            let date = CodeStatsPageFixture.date("2026-10-05")
            let environment = CodeStatsEnvironment(
                settings: { .init() }, saveIdentity: { _ in }, isEnabled: { true }, git: { nil },
                github: { nil }, store: harness.store, calendar: CodeStatsPageFixture.calendar,
                now: { date })
            let workflow = CodeStatsWorkflow(environment: environment)
            commands = CodeStatsCommands(
                workflow: workflow, store: harness.store, defaults: defaults,
                home: harness.fixture.root)
            try harness.store.saveFacts(
                CodeStatsFactBuilder.build(commits: CodeStatsPageFixture.commits))
        }
        func call(_ command: String, _ object: [String: Any]) async throws -> Data {
            try await commands.execute(
                command, payload: JSONSerialization.data(withJSONObject: object))
        }
        func remove() { defaults.removePersistentDomain(forName: suite); harness.fixture.remove() }
    }
}
