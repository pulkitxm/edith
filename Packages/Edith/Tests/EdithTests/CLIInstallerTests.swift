import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIInstallerTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeTool(_ name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func installLinksEveryToolName() throws {
        let tools = try Self.temporaryDirectory()
        let bin = try Self.temporaryDirectory()
        try Self.makeTool("ed", in: tools)
        try Self.makeTool("edh", in: tools)

        let result = CLIInstaller.install(toolsDirectory: tools, into: bin)
        #expect(result.linked == ["ed", "edh", "edith"])
        for name in CLIInstaller.toolNames {
            let destination = try FileManager.default.destinationOfSymbolicLink(
                atPath: bin.appendingPathComponent(name).path)
            #expect(destination.hasPrefix(tools.path))
        }
        let aliasTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: bin.appendingPathComponent("edith").path)
        #expect(aliasTarget.hasSuffix("/ed"))
        try? FileManager.default.removeItem(at: tools)
        try? FileManager.default.removeItem(at: bin)
    }

    @Test func installingTwiceIsANoOp() throws {
        let tools = try Self.temporaryDirectory()
        let bin = try Self.temporaryDirectory()
        try Self.makeTool("ed", in: tools)
        try Self.makeTool("edh", in: tools)
        _ = CLIInstaller.install(toolsDirectory: tools, into: bin)
        let second = CLIInstaller.install(toolsDirectory: tools, into: bin)
        #expect(second.linked.isEmpty)
        #expect(second.skipped.isEmpty)
        try? FileManager.default.removeItem(at: tools)
        try? FileManager.default.removeItem(at: bin)
    }

    @Test func aRealFileThatIsNotOursIsNeverReplaced() throws {
        let tools = try Self.temporaryDirectory()
        let bin = try Self.temporaryDirectory()
        try Self.makeTool("ed", in: tools)
        try Self.makeTool("edh", in: tools)
        let squatter = bin.appendingPathComponent("ed")
        try Data("someone else".utf8).write(to: squatter)

        let result = CLIInstaller.install(toolsDirectory: tools, into: bin)
        let untouched = try String(contentsOf: squatter, encoding: .utf8)
        #expect(result.skipped.contains("ed"))
        #expect(untouched == "someone else")
        try? FileManager.default.removeItem(at: tools)
        try? FileManager.default.removeItem(at: bin)
    }

    @Test func aStaleLinkFromAnEarlierInstallIsRepointed() throws {
        let oldTools = try Self.temporaryDirectory()
        let newTools = try Self.temporaryDirectory()
        let bin = try Self.temporaryDirectory()
        for directory in [oldTools, newTools] {
            try Self.makeTool("ed", in: directory)
            try Self.makeTool("edh", in: directory)
        }
        _ = CLIInstaller.install(toolsDirectory: oldTools, into: bin)
        let result = CLIInstaller.install(toolsDirectory: newTools, into: bin)
        let repointed = try FileManager.default.destinationOfSymbolicLink(
            atPath: bin.appendingPathComponent("ed").path)
        #expect(result.linked == CLIInstaller.toolNames)
        #expect(repointed.hasPrefix(newTools.path))
        for directory in [oldTools, newTools, bin] {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func uninstallOnlyRemovesLinks() throws {
        let tools = try Self.temporaryDirectory()
        let bin = try Self.temporaryDirectory()
        try Self.makeTool("ed", in: tools)
        try Self.makeTool("edh", in: tools)
        _ = CLIInstaller.install(toolsDirectory: tools, into: bin)
        let keep = bin.appendingPathComponent("keepme")
        try Data("x".utf8).write(to: keep)

        let result = CLIInstaller.uninstall(from: bin)
        #expect(Set(result.linked) == Set(CLIInstaller.toolNames))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        for name in CLIInstaller.toolNames {
            #expect(!FileManager.default.fileExists(atPath: bin.appendingPathComponent(name).path))
        }
        try? FileManager.default.removeItem(at: tools)
        try? FileManager.default.removeItem(at: bin)
    }

    @Test func theToolsDirectoryIsFoundFromANestedHelperBundle() throws {
        let root = try Self.temporaryDirectory()
        let app = root.appendingPathComponent("Edith.app")
        let tools = app.appendingPathComponent("Contents/MacOS")
        let helper = app.appendingPathComponent(
            "Contents/Library/LoginItems/Edith.app")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try Self.makeTool("ed", in: tools)

        #expect(CLIInstaller.bundledToolsDirectory(from: helper)?.path == tools.path)
        #expect(CLIInstaller.bundledToolsDirectory(from: root) == nil)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func pathMembershipIgnoresTrailingSlashes() {
        let directory = URL(fileURLWithPath: "/usr/local/bin")
        #expect(CLIInstaller.isOnPath(directory, entries: ["/usr/bin", "/usr/local/bin/"]))
        #expect(!CLIInstaller.isOnPath(directory, entries: ["/usr/bin"]))
    }

    @Test func pathEntriesSplitOnColons() {
        #expect(CLIInstaller.pathEntries(["PATH": "/a:/b"]) == ["/a", "/b"])
        #expect(CLIInstaller.pathEntries([:]).isEmpty)
    }

    @Test func completionScriptsCoverEveryShellAndNameEveryAlias() {
        for shell in CompletionScripts.Shell.allCases {
            let script = CompletionScripts.script(for: shell)
            #expect(script.contains("ed"))
            #expect(script.contains("edith"))
            #expect(script.contains("__complete"))
        }
        #expect(CompletionScripts.script(for: .zsh).hasPrefix("#compdef ed edh edith"))
    }

    @Test func completionScriptsGoWhereTheirShellLooksForThem() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(
            CompletionScripts.installDirectory(for: .zsh, home: home).path
                == "/Users/example/.local/share/zsh/site-functions")
        #expect(
            CompletionScripts.installDirectory(for: .fish, home: home).path
                == "/Users/example/.config/fish/completions")
        #expect(CompletionScripts.rcHint(for: .fish, directory: home) == nil)
    }
}
