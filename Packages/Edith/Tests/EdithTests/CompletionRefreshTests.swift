import Foundation
import Testing

@testable import EdithKit

@Suite struct CompletionRefreshTests {
    private func makeHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edith-completions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeStore() -> UserDefaults {
        let store = UserDefaults(suiteName: "edith.tests.\(UUID().uuidString)")!
        store.removeObject(forKey: CompletionScripts.recordKey)
        return store
    }

    @Test func callsTheToolByAbsolutePathSoPathCannotShadowIt() {
        let script = CompletionScripts.script(for: .zsh, tool: "/opt/edith/ed")
        #expect(script.contains("local __ed=/opt/edith/ed"))
        #expect(script.contains("[[ -x $__ed ]] || __ed=ed"))
        #expect(!script.contains("command ed __complete"))
    }

    @Test func quotesAToolPathWithASpaceInIt() {
        let script = CompletionScripts.script(for: .zsh, tool: "/Users/a b/ed")
        #expect(script.contains("local __ed='/Users/a b/ed'"))
    }

    @Test func embedsTheToolPathInEveryShell() {
        for shell in CompletionScripts.Shell.allCases {
            let script = CompletionScripts.script(for: shell, tool: "/opt/edith/ed")
            #expect(script.contains("/opt/edith/ed"))
            #expect(CompletionScripts.isOurs(script))
        }
    }

    @Test func zshScriptWorksAutoloadedAndSourced() {
        let script = CompletionScripts.zsh
        #expect(script.hasPrefix("#compdef ed edh edith"))
        #expect(script.contains("_ed_complete() {"))
        #expect(script.contains("if [[ $zsh_eval_context[-1] == loadautofunc ]]; then"))
        #expect(script.contains("_ed_complete \"$@\""))
        #expect(script.contains("compdef _ed_complete ed edh edith"))
        #expect(script.contains("compadd -- \"${matches[@]}\""))
    }

    @Test func refreshInstallsForEveryDetectedShell() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent(".bashrc"))

        let written = CompletionScripts.refreshInstalled(home: home, store: makeStore())
        let names = written.map { $0.lastPathComponent }
        #expect(names.contains("_ed"))
        #expect(names.contains("ed"))
        for file in written {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            #expect(CompletionScripts.isOurs(text))
        }
    }

    @Test func refreshDoesNothingOnceTheRecordedScriptIsCurrent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore()

        #expect(!CompletionScripts.refreshInstalled(home: home, store: store).isEmpty)
        #expect(CompletionScripts.refreshInstalled(home: home, store: store).isEmpty)
    }

    @Test func refreshRewritesAScriptLeftBehindByAnOlderVersion() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = CompletionScripts.defaultDirectory(for: .zsh, home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("_ed")
        try Data("#compdef ed\n_ed_complete() { command ed __complete; }\n".utf8).write(to: stale)

        CompletionScripts.refreshInstalled(home: home, store: makeStore())

        let text = String(decoding: try Data(contentsOf: stale), as: UTF8.self)
        #expect(text == CompletionScripts.contents(for: .zsh))
    }

    @Test func refreshLeavesAFileItDoesNotOwnAlone() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = CompletionScripts.defaultDirectory(for: .zsh, home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("_ed")
        try Data("#compdef ed\n_gnu_ed_completion\n".utf8).write(to: foreign)

        let store = makeStore()
        CompletionScripts.record(foreign, for: .zsh, store: store)
        CompletionScripts.refreshInstalled(home: home, store: store)

        let text = String(decoding: try Data(contentsOf: foreign), as: UTF8.self)
        #expect(text == "#compdef ed\n_gnu_ed_completion\n")
    }

    @Test func installRecordsWhereTheScriptLanded() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = makeStore()

        let file = try CompletionScripts.install(.fish, home: home, store: store)
        #expect(CompletionScripts.recordedPath(for: .fish, store: store)?.path == file.path)
    }
}
