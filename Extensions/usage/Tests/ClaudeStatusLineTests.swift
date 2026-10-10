import Foundation
import Testing

@testable import UsageExtension

@Suite struct ClaudeStatusLineTests {
    private let executable = "/Applications/Edith.app/Contents/MacOS/Edith"

    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-statusline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func statusInput(session: Double, sessionReset: Int, week: Double, weekReset: Int)
        -> Data
    {
        Data(
            """
            {"model":{"display_name":"Synthetic"},"rate_limits":{\
            "five_hour":{"used_percentage":\(session),"resets_at":\(sessionReset)},\
            "seven_day":{"used_percentage":\(week),"resets_at":\(weekReset)}}}
            """.utf8)
    }

    private func document(at url: URL) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func limitsComeFromTheDocumentedStatusLineFields() throws {
        let limits = try #require(
            ClaudeStatusLine.limits(
                from: statusInput(
                    session: 23.5, sessionReset: 1_738_425_600, week: 41.2,
                    weekReset: 1_738_857_600)))
        #expect(limits.session?.percent == 23.5)
        #expect(limits.session?.resetsAt == Date(timeIntervalSince1970: 1_738_425_600))
        #expect(limits.week?.percent == 41.2)
        #expect(limits.week?.resetsAt == Date(timeIntervalSince1970: 1_738_857_600))
        #expect(ClaudeStatusLine.line(for: limits) == "5h 24% · 7d 41%")
    }

    @Test func inputWithoutRateLimitsRecordsNothing() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("limits-history.jsonl")
        let input = Data(#"{"model":{"display_name":"Synthetic"}}"#.utf8)
        #expect(ClaudeStatusLine.limits(from: input) == nil)
        #expect(ClaudeStatusLine.record(input, history: history) == nil)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }

    @Test func recordSavesAClaudeRowInTheLimitsHistory() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("limits-history.jsonl")
        let input = statusInput(
            session: 57, sessionReset: 4_102_444_800, week: 15, weekReset: 4_102_531_200)

        #expect(ClaudeStatusLine.record(input, history: history) != nil)

        let latest = try #require(LimitsHistory.latest(provider: .claude, url: history))
        #expect(latest.session?.percent == 57)
        #expect(latest.week?.percent == 15)
        #expect(latest.week?.resetsAt == Date(timeIntervalSince1970: 4_102_531_200))
    }

    @Test func statusLinePreservesTheWebsiteFableWindowUntilItsReset() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("limits-history.jsonl")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fable = LimitWindow(percent: 7, resetsAt: now.addingTimeInterval(3600))
        var store = LimitsHistory(url: history)
        store.append(provider: .claude, session: nil, week: nil, fable: fable, now: now)
        let input = statusInput(
            session: 23, sessionReset: 4_102_444_800, week: 41, weekReset: 4_102_531_200)
        ClaudeStatusLine.record(input, now: now.addingTimeInterval(10), history: history)
        #expect(LimitsHistory.latest(provider: .claude, url: history)?.fable == fable)
        ClaudeStatusLine.record(input, now: now.addingTimeInterval(3601), history: history)
        #expect(LimitsHistory.latest(provider: .claude, url: history)?.fable == nil)
    }

    @Test func installAddsTheRecorderAndKeepsOtherSettings() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"model":"synthetic","hooks":{}}"#.utf8).write(to: settings)

        #expect(
            try ClaudeStatusLine.install(executable: executable, settings: settings) == .installed)
        #expect(
            try ClaudeStatusLine.install(executable: executable, settings: settings) == .unchanged)

        let saved = try document(at: settings)
        let statusLine = try #require(saved["statusLine"] as? [String: Any])
        #expect(saved["model"] as? String == "synthetic")
        #expect(saved["hooks"] is [String: Any])
        #expect(statusLine["type"] as? String == "command")
        #expect(
            statusLine["command"] as? String
                == "'\(executable)' extension command usage usage.statusline.record")
        #expect(ClaudeStatusLine.isInstalled(settings: settings))
    }

    @Test func installCreatesMissingSettings() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("config/settings.json")

        #expect(
            try ClaudeStatusLine.install(executable: executable, settings: settings) == .installed)
        #expect(ClaudeStatusLine.isInstalled(settings: settings))
    }

    @Test func installWrapsAnExistingCommandAndRemoveRestoresIt() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let previous = "printf 'it'\\''s mine' && date"
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": previous, "padding": 1]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        #expect(
            try ClaudeStatusLine.install(executable: executable, settings: settings) == .wrapped)
        let installed = try #require(try document(at: settings)["statusLine"] as? [String: Any])
        let command = try #require(installed["command"] as? String)
        #expect(ClaudeStatusLine.isRecorder(command))
        #expect(ClaudeStatusLine.wrappedCommand(in: command) == previous)
        #expect(installed["padding"] as? Int == 1)
        #expect(
            try ClaudeStatusLine.install(executable: executable, settings: settings) == .unchanged)

        #expect(try ClaudeStatusLine.remove(settings: settings) == .restored)
        let restored = try #require(try document(at: settings)["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == previous)
        #expect(restored["padding"] as? Int == 1)
        #expect(!ClaudeStatusLine.isInstalled(settings: settings))
    }

    @Test func removeDropsTheStatusLineItAddedAndLeavesOthersAlone() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let foreign = Data(#"{"statusLine":{"type":"command","command":"date"}}"#.utf8)
        try foreign.write(to: settings)

        #expect(try ClaudeStatusLine.remove(settings: settings) == .absent)
        #expect(try Data(contentsOf: settings) == foreign)

        try Data(#"{"model":"synthetic"}"#.utf8).write(to: settings)
        try ClaudeStatusLine.install(executable: executable, settings: settings)
        #expect(try ClaudeStatusLine.remove(settings: settings) == .removed)
        let saved = try document(at: settings)
        #expect(saved["statusLine"] == nil)
        #expect(saved["model"] as? String == "synthetic")
    }

    @Test func unreadableSettingsAreNeverOverwritten() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let broken = Data("{ not json".utf8)
        try broken.write(to: settings)

        #expect(throws: ClaudeStatusLine.Failure.unreadable(settings.path)) {
            try ClaudeStatusLine.install(executable: executable, settings: settings)
        }
        #expect(try Data(contentsOf: settings) == broken)
        #expect(!ClaudeStatusLine.isInstalled(settings: settings))
    }

    @Test func symlinkedSettingsStayASymlink() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("dotfiles-settings.json")
        let link = root.appendingPathComponent("settings.json")
        try Data(#"{"model":"synthetic"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try ClaudeStatusLine.install(executable: executable, settings: link)

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(ClaudeStatusLine.isInstalled(settings: real))
    }

    @Test func settingsFollowClaudeConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/synthetic", isDirectory: true)
        #expect(
            ClaudeStatusLine.settingsURL(environment: [:], home: home).path
                == "/Users/synthetic/.claude/settings.json")
        #expect(
            ClaudeStatusLine.settingsURL(
                environment: ["CLAUDE_CONFIG_DIR": "/tmp/synthetic-claude"], home: home
            ).path == "/tmp/synthetic-claude/settings.json")
    }

    @Test func snapshotExplainsSetupAndDropsWindowsThatAlreadyReset() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let history = root.appendingPathComponent("limits-history.jsonl")
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let missing = ClaudeStatusLine.snapshot(now: now, settings: settings, history: history)
        #expect(missing.error == ClaudeStatusLine.setupHint)
        #expect(missing.session == nil)

        try ClaudeStatusLine.install(executable: executable, settings: settings)
        ClaudeStatusLine.record(
            statusInput(
                session: 57, sessionReset: 1_999_999_000, week: 15, weekReset: 2_000_400_000),
            now: now, history: history)

        let snapshot = ClaudeStatusLine.snapshot(now: now, settings: settings, history: history)
        #expect(snapshot.provider == .claude)
        #expect(snapshot.error == nil)
        #expect(snapshot.session == nil)
        #expect(snapshot.week?.percent == 15)
    }

    @Test func applicationExecutableIsUsedDirectly() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Edith")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(ClaudeStatusLine.launcher(beside: executable) == executable.path)
        #expect(ClaudeStatusLine.launcher(beside: root.appendingPathComponent("missing")) == nil)
    }

    @Test func oversizedStatusLineInputRecordsNothing() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("limits.jsonl")
        let input = Data(repeating: 32, count: 1_024 * 1_024 + 1)
        #expect(ClaudeStatusLine.record(input, history: history) == nil)
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }
}
