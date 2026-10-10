import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCoreCompletionRefreshTests {
    @Test func launcherUpdateRefreshesOnlyExistingManagedScriptsWithoutProfileWrites() throws {
        let fixture = try CompletionRefreshFixture()
        defer { fixture.remove() }
        let previous = fixture.tooling(executable: fixture.root.appendingPathComponent("old ' ed"))
        let current = fixture.tooling()
        for shell in HostToolingCLI.Shell.allCases {
            let file = previous.completionFile(shell)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((previous.script(shell) + "\n").utf8).write(to: file)
        }
        let profile = fixture.root.appendingPathComponent(".zshrc")
        let profileBytes = Data("export SYNTHETIC=1\n".utf8)
        try profileBytes.write(to: profile)
        #expect(current.refreshExistingCompletions(enabled: true).count == 3)
        for shell in HostToolingCLI.Shell.allCases {
            #expect(
                try Data(contentsOf: current.completionFile(shell))
                    == Data((current.script(shell) + "\n").utf8))
        }
        #expect(try Data(contentsOf: profile) == profileBytes)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(".bashrc").path))
        #expect(current.refreshExistingCompletions(enabled: true).isEmpty)
    }

    @Test func falseFlagMissingFilesAndUnrelatedCompletionContentsAreUntouched() throws {
        let fixture = try CompletionRefreshFixture()
        defer { fixture.remove() }
        let current = fixture.tooling()
        #expect(current.refreshExistingCompletions(enabled: true).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: current.completionFile(.zsh).path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent(".zshrc").path))
        let previous = fixture.tooling(
            executable: fixture.root.appendingPathComponent("previous ed"))
        let file = previous.completionFile(.zsh)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = Data((previous.script(.zsh) + "\n").utf8)
        try saved.write(to: file)
        #expect(current.refreshExistingCompletions(enabled: false).isEmpty)
        #expect(try Data(contentsOf: file) == saved)
        let unrelated = Data((previous.script(.zsh) + "\nprint synthetic __complete\n").utf8)
        try unrelated.write(to: file)
        #expect(current.refreshExistingCompletions(enabled: true).isEmpty)
        #expect(try Data(contentsOf: file) == unrelated)
        let oversized = Data(repeating: 65, count: 65_537)
        try oversized.write(to: file)
        #expect(current.refreshExistingCompletions(enabled: true).isEmpty)
        #expect(try Data(contentsOf: file) == oversized)
    }

    @Test func symlinkAndHardLinkedTargetsAreNeverRefreshed() throws {
        let fixture = try CompletionRefreshFixture()
        defer { fixture.remove() }
        let current = fixture.tooling()
        let previous = fixture.tooling(
            executable: fixture.root.appendingPathComponent("previous ed"))
        let file = previous.completionFile(.zsh)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("unrelated")
        let saved = Data((previous.script(.zsh) + "\n").utf8)
        try saved.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(current.refreshExistingCompletions(enabled: true).isEmpty)
        #expect(try Data(contentsOf: target) == saved)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        #expect(current.refreshExistingCompletions(enabled: true).isEmpty)
        #expect(try Data(contentsOf: target) == saved)
    }
}

private struct CompletionRefreshFixture {
    let root: URL
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "completion-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("current ' ed")
        try Data("exit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func tooling(executable: URL? = nil) -> HostToolingCLI {
        HostToolingCLI(
            home: root, executable: executable ?? self.executable,
            directory: root.appendingPathComponent("bin"), path: [])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
