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

    @Test func sanitizedToolEnvironmentRemovesNoColor() {
        let environment = CLIToolEnvironment.sanitized(
            processEnvironment: [
                "PATH": "/usr/bin",
                "NO_COLOR": "1",
                "PRESERVED": "value",
            ])

        #expect(environment["NO_COLOR"] == nil)
        #expect(environment["PRESERVED"] == "value")
    }

    @Test func terminalToolingDescriptorsAreRegisteredAndExact() {
        let descriptors = TerminalToolingOperation.allCases.map(\.descriptor)
        #expect(
            descriptors.map(\.cli) == [
                ["status"], ["install"], ["uninstall"],
                ["completions", "install"], ["completions", "source"],
            ])
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(cli: $0.cli) == $0 })
    }

    @Test func sharedStatusIncludesToolsCompletionsAndFallbackSource() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: home.appendingPathComponent(".bashrc"))

        let status = TerminalToolingOperationExecution.status(
            home: home, environment: ["PATH": "/usr/bin"], store: makeStore())

        #expect(status.tools.directory == CLIInstaller.preferredDirectory(home: home).path)
        #expect(status.completions.map(\.shell).contains(.zsh))
        #expect(status.completions.map(\.shell).contains(.bash))
        #expect(status.fallbackSourceLine.hasPrefix("source "))
    }

    @Test func sharedInstallAndRemoveUseTheSameNamedLinks() throws {
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools")
        let target = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let file = tools.appendingPathComponent("ed")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path)

        let installed = TerminalToolingOperationExecution.install(
            toolsDirectory: tools, into: target,
            environment: ["PATH": target.path])
        #expect(installed.succeeded)
        #expect(Set(installed.result.linked) == Set(CLIInstaller.toolNames))
        #expect(installed.onPath)
        let alreadyInstalled = TerminalToolingOperationExecution.install(
            toolsDirectory: tools, into: target,
            environment: ["PATH": target.path])
        #expect(alreadyInstalled.succeeded)
        #expect(alreadyInstalled.result.linked.isEmpty)

        let removed = TerminalToolingOperationExecution.remove(from: target)
        #expect(removed.succeeded)
        #expect(Set(removed.result.linked) == Set(CLIInstaller.toolNames))
        #expect(
            CLIInstaller.toolNames.allSatisfy {
                !FileManager.default.fileExists(atPath: target.appendingPathComponent($0).path)
            })
    }

    @Test func completionInstallReportsEachShellFailureWithoutDroppingSuccesses() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".bashrc"), withIntermediateDirectories: true)

        let outcome = TerminalToolingOperationExecution.installCompletions(
            shells: [.zsh, .bash], home: home, store: makeStore())

        #expect(outcome.installed.map(\.shell) == [.zsh])
        #expect(outcome.failures.map(\.shell) == [.bash])
        #expect(!outcome.failures[0].message.isEmpty)
        #expect(!outcome.succeeded)
    }

    @Test func fallbackSourceSelectsTheRequestedShell() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let line = TerminalToolingOperationExecution.fallbackSource(
            for: .fish, home: home, store: makeStore())
        #expect(line == "source $HOME/.config/fish/completions/ed.fish")
    }
}
