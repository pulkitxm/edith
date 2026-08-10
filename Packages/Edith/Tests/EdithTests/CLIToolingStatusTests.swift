import Foundation
import Testing

@testable import EdithKit

@Suite struct CLIToolingStatusTests {
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edith-tooling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeStore() -> UserDefaults {
        UserDefaults(suiteName: "edith.tests.\(UUID().uuidString)")!
    }

    private func write(_ text: String, for shell: CompletionScripts.Shell, home: URL) throws -> URL
    {
        let directory = CompletionScripts.defaultDirectory(for: shell, home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(shell.scriptName)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func reportsAMissingScript() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let status = CompletionScripts.status(for: .fish, home: home, store: makeStore())
        #expect(status.state == .missing)
        #expect(status.path.lastPathComponent == "ed.fish")
    }

    @Test func reportsAScriptItJustWrote() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore()
        try CompletionScripts.install(.fish, home: home, store: store)
        #expect(CompletionScripts.status(for: .fish, home: home, store: store).state == .current)
    }

    @Test func reportsAScriptFromAnOlderVersion() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try write(
            "#compdef ed\n_ed_complete() { command ed __complete; }\n", for: .zsh, home: home)
        #expect(
            CompletionScripts.status(for: .zsh, home: home, store: makeStore()).state == .outdated)
    }

    @Test func leavesSomeoneElsesScriptAlone() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try write("#compdef ed\n_gnu_ed_completion\n", for: .zsh, home: home)
        #expect(
            CompletionScripts.status(for: .zsh, home: home, store: makeStore()).state == .foreign)
    }

    @Test func findsTheScriptWhereItWasRecorded() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore()
        let elsewhere = home.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let file = elsewhere.appendingPathComponent("ed.fish")
        try Data(CompletionScripts.contents(for: .fish).utf8).write(to: file)
        CompletionScripts.record(file, for: .fish, store: store)

        let status = CompletionScripts.status(for: .fish, home: home, store: store)
        #expect(status.path.path == file.path)
        #expect(status.state == .current)
    }

    @Test func listsAStatusForEveryDetectedShell() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent(".bashrc"))
        let shells = CompletionScripts.statuses(home: home, store: makeStore()).map(\.shell)
        #expect(shells.contains(.zsh))
        #expect(shells.contains(.bash))
    }

    @Test func countsToolsThatAreNotLinkedYet() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let status = CLIInstaller.status(home: home, environment: ["PATH": "/usr/bin"])
        #expect(status.linked.isEmpty)
        #expect(Set(status.missing) == Set(CLIInstaller.toolNames))
        #expect(!status.isComplete)
        #expect(!status.onPath)
    }

    @Test func noticesTheDirectoryIsOnPath() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = CLIInstaller.preferredDirectory(home: home)
        let status = CLIInstaller.status(
            home: home, environment: ["PATH": "/usr/bin:\(target.path)"])
        #expect(status.onPath)
    }
}
