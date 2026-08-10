import Foundation
import Testing

@testable import EdithKit

@Suite struct ShellProfileTests {
    private let line = "source $HOME/.zsh/completions/_ed"
    private let script = "/Users/someone/.zsh/completions/_ed"

    private func makeFile(_ contents: String?) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zshrc-\(UUID().uuidString)")
        if let contents { try Data(contents.utf8).write(to: url) }
        return url
    }

    private func read(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    @Test func writesAMarkedBlock() {
        let block = ShellProfile.block(line)
        #expect(block == "# >>> edith completions >>>\n\(line)\n# <<< edith completions <<<")
    }

    @Test func keepsWhatWasAlreadyInTheFile() {
        let result = ShellProfile.applying(line, to: "export PATH=/usr/bin\nalias k=kubectl\n")
        #expect(result.hasPrefix("export PATH=/usr/bin\nalias k=kubectl"))
        #expect(result.contains(ShellProfile.block(line)))
    }

    @Test func replacesItsOwnBlockInsteadOfStacking() {
        let first = ShellProfile.applying("source /old/path", to: "alias k=kubectl\n")
        let second = ShellProfile.applying(line, to: first)
        #expect(second.components(separatedBy: ShellProfile.beginMarker).count == 2)
        #expect(!second.contains("/old/path"))
        #expect(second.contains(line))
        #expect(second.contains("alias k=kubectl"))
    }

    @Test func readsBackTheLineItManages() {
        let text = ShellProfile.applying(line, to: "alias k=kubectl\n")
        #expect(ShellProfile.managedLine(in: text) == line)
    }

    @Test func hasNoManagedLineInAnUntouchedFile() {
        #expect(ShellProfile.managedLine(in: "alias k=kubectl\n") == nil)
    }

    @Test func adoptsALineTheUserAddedByHand() {
        let byHand = "alias k=kubectl\nsource $HOME/.zsh/completions/_ed\n"
        let result = ShellProfile.applying(line, to: byHand, script: script)
        #expect(result.components(separatedBy: "source ").count == 2)
        #expect(result.contains(ShellProfile.beginMarker))
        #expect(result.contains("alias k=kubectl"))
    }

    @Test func leavesUnrelatedSourceLinesAlone() {
        let other = "source $HOME/.zsh/completions/_kubectl\n"
        let result = ShellProfile.applying(line, to: other, script: script)
        #expect(result.contains("_kubectl"))
    }

    @Test func writesTheBlockIntoAFileThatDoesNotExistYet() throws {
        let file = try makeFile(nil)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ShellProfile.install(line: line, into: file, script: script))
        #expect(ShellProfile.managedLine(in: read(file)) == line)
    }

    @Test func doesNotRewriteAFileThatIsAlreadyRight() throws {
        let file = try makeFile("alias k=kubectl\n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ShellProfile.install(line: line, into: file, script: script))
        #expect(try ShellProfile.install(line: line, into: file, script: script) == false)
    }

    @Test func rewritesWhenTheScriptMoved() throws {
        let file = try makeFile(nil)
        defer { try? FileManager.default.removeItem(at: file) }
        try ShellProfile.install(line: "source /old/path", into: file)
        #expect(try ShellProfile.install(line: line, into: file, script: script))
        #expect(ShellProfile.managedLine(in: read(file)) == line)
    }

    @Test func takesItsBlockBackOutAgain() throws {
        let file = try makeFile("alias k=kubectl\n")
        defer { try? FileManager.default.removeItem(at: file) }
        try ShellProfile.install(line: line, into: file, script: script)
        #expect(try ShellProfile.uninstall(from: file))
        #expect(read(file) == "alias k=kubectl\n")
        #expect(try ShellProfile.uninstall(from: file) == false)
    }

    @Test func sendsZshAndBashToTheirOwnFiles() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(ShellProfile.file(for: .zsh, home: home)?.lastPathComponent == ".zshrc")
        #expect(ShellProfile.file(for: .bash, home: home)?.lastPathComponent == ".bashrc")
        #expect(ShellProfile.file(for: .fish, home: home) == nil)
    }

    @Test func installingCompletionsWiresUpTheProfile() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edith-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = UserDefaults(suiteName: "edith.tests.\(UUID().uuidString)")!

        let script = try CompletionScripts.install(.zsh, home: home, store: store)
        let rc = read(home.appendingPathComponent(".zshrc"))
        #expect(
            ShellProfile.managedLine(in: rc)
                == CompletionScripts.sourceLine(forScript: script, home: home))
        #expect(ShellProfile.managedLine(in: rc)?.hasPrefix("source $HOME/") == true)
    }
}
