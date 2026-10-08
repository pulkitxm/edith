import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct LaTeXCLITests {
    @Test func localEditingPreviewsCompilesAndRejectsStaleRevisions() async throws {
        try await CLIProbe.inWorld { world in
            defer { LaTeXCLIEnvironment.reset() }
            let source = world.sandbox.appendingPathComponent("main.tex")
            try Data("Hello draft".utf8).write(to: source)
            LaTeXCLIEnvironment.store = LaTeXProjectStore(
                url: world.sandbox.appendingPathComponent("projects.json"))
            LaTeXCLIEnvironment.service = LaTeXService { tool, _, _, directory in
                #expect(tool == "tectonic")
                #expect(directory?.path == source.deletingLastPathComponent().path)
                try Data("%PDF-1.7\nsynthetic".utf8).write(
                    to: source.deletingPathExtension().appendingPathExtension("pdf"))
                return Data("compiled".utf8)
            }
            let added = await CLIProbe.capture([
                "latex", "add", "--name", "Paper", "--file", source.path, "--json",
            ])
            #expect(added.code == 0)
            let id = try #require(added.object?["id"] as? String)
            let read = await CLIProbe.capture(["latex", "read", id, "--json"])
            let revision = try #require(read.object?["revision"] as? String)
            #expect(revision.count == 64)
            LaTeXCLIEnvironment.input = {
                Data(#"[{"find":"draft","replace":"paper","expectedMatches":1}]"#.utf8)
            }
            let args = ["latex", "edit", id, "--revision", revision, "--json"]
            let preview = await CLIProbe.capture(args)
            #expect(preview.code == 0 && preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["source"] as? String == "Hello paper")
            #expect(try String(contentsOf: source, encoding: .utf8) == "Hello draft")
            let applied = await CLIProbe.capture(args + ["--yes"])
            #expect(applied.code == 0 && applied.object?["applied"] as? Bool == true)
            #expect(try String(contentsOf: source, encoding: .utf8) == "Hello paper")
            let stale = await CLIProbe.capture(args + ["--yes"])
            #expect(stale.code != 0 && stale.stderr.contains("revision changed"))
            let pdf = await CLIProbe.capture(["latex", "preview", id, "--data", "--json"])
            #expect(pdf.object?["available"] as? Bool == true)
            #expect(pdf.object?["pdfBase64"] as? String != nil)
            let removed = await CLIProbe.capture(["latex", "remove", id, "--yes", "--json"])
            #expect(removed.code == 0)
            #expect(try LaTeXCLIEnvironment.store.load().isEmpty)
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func failedEditPlansNeverChangeSource() throws {
        let first = LaTeXTextEdit(find: "draft", replace: "paper", expectedMatches: 1)
        let invalid = LaTeXTextEdit(find: "missing", replace: "text", expectedMatches: 1)
        #expect(throws: CLIFailure.self) { try LaTeXTextEdit.apply([first, invalid], to: "draft") }
        #expect(throws: CLIFailure.self) { try LaTeXTextEdit.apply([first], to: "draft draft") }
        #expect(
            try LaTeXTextEdit.apply(
                [first, LaTeXTextEdit(find: "paper", replace: "final", expectedMatches: 1)],
                to: "draft") == "final")
    }

    @Test func repositoryWriteSavesOnlyPointersAndUsesPukbot() async throws {
        try await CLIProbe.inWorld { world in
            defer { LaTeXCLIEnvironment.reset() }
            let calls = LaTeXCLICalls()
            LaTeXCLIEnvironment.store = LaTeXProjectStore(
                url: world.sandbox.appendingPathComponent("projects.json"))
            LaTeXCLIEnvironment.service = LaTeXService { tool, args, input, directory in
                #expect(directory == nil)
                await calls.record([tool] + args)
                if tool == "pukbot" {
                    #expect(args == ["apply", "--input", "-", "--json"])
                    let data = try #require(input)
                    let commit = try #require(
                        JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let files = try #require(commit["files"] as? [[String: String]])
                    #expect(files[0]["content"] == "New source")
                    return Data()
                }
                if args.contains(where: { $0.contains("git/ref") }) {
                    return Data(#"{"object":{"sha":"head"}}"#.utf8)
                }
                if args.contains(where: { $0.contains("/pulls") }) {
                    return Data(#"[{"number":42}]"#.utf8)
                }
                return Data(
                    #"{"type":"file","encoding":"base64","content":"SGVsbG8=","sha":"blob"}"#.utf8)
            }
            let project = LaTeXProject(
                name: "Paper", location: .github, sourcePath: "docs/main.tex", compiler: .pdfLatex,
                repository: "northstar/paper", baseBranch: "main")
            try LaTeXCLI.persist(project)
            let read = await CLIProbe.capture(["latex", "read", project.id.uuidString, "--json"])
            let revision = try #require(read.object?["revision"] as? String)
            LaTeXCLIEnvironment.input = { Data("New source".utf8) }
            let result = await CLIProbe.capture([
                "latex", "write", project.id.uuidString, "--revision", revision, "--yes", "--json",
            ])
            #expect(result.code == 0)
            let stored = try #require(LaTeXCLIEnvironment.store.load().first)
            #expect(stored.pullRequest == 42 && stored.reviewBranch != nil)
            let metadata = try String(contentsOf: LaTeXCLIEnvironment.store.url, encoding: .utf8)
            #expect(!metadata.contains("New source") && !metadata.contains("Hello"))
            #expect(await calls.values.contains { $0.first == "pukbot" })
            #expect(await !calls.values.contains { $0.first == "git" || $0.first == "tectonic" })
        }
    }

    @Test func mergeRequiresExplicitApplyAndRepositoryPointer() async throws {
        try await CLIProbe.inWorld { world in
            defer { LaTeXCLIEnvironment.reset() }
            let calls = LaTeXCLICalls()
            LaTeXCLIEnvironment.store = LaTeXProjectStore(
                url: world.sandbox.appendingPathComponent("projects.json"))
            LaTeXCLIEnvironment.service = LaTeXService { tool, args, _, _ in
                await calls.record([tool] + args)
                #expect(
                    tool == "pukbot" && args.contains("--delete-branch") && args.contains("--auto"))
                return Data()
            }
            let project = LaTeXProject(
                name: "Paper", location: .github, sourcePath: "main.tex",
                repository: "northstar/paper", baseBranch: "main", reviewBranch: "latex/paper",
                pullRequest: 42)
            try LaTeXCLI.persist(project)
            let args = ["latex", "merge", project.id.uuidString, "--auto", "--json"]
            let plan = await CLIProbe.capture(args)
            #expect(plan.object?["applied"] as? Bool == false)
            #expect(await calls.values.isEmpty)
            let applied = await CLIProbe.capture(args + ["--yes"])
            #expect(applied.code == 0 && applied.object?["applied"] as? Bool == true)
        }
    }

    @Test func repositoryCompileRebuildsMergedHeadThroughPukbot() async throws {
        try await CLIProbe.inWorld { world in
            defer { LaTeXCLIEnvironment.reset() }
            let project = LaTeXProject(
                name: "Paper", location: .github, sourcePath: "main.tex",
                repository: "northstar/paper", baseBranch: "main", reviewBranch: "latex/paper",
                pullRequest: 42)
            LaTeXCLIEnvironment.store = LaTeXProjectStore(
                url: world.sandbox.appendingPathComponent("projects.json"))
            try LaTeXCLI.persist(project)
            LaTeXCLIEnvironment.service = LaTeXService { tool, args, input, directory in
                #expect(input == nil && directory == nil)
                if tool == "pukbot" {
                    #expect(
                        args == ["workflow", "rerun", "--repo", project.repository, "72", "--json"])
                    return Data()
                }
                if args.contains("view") {
                    return Data(
                        #"{"number":42,"title":"Paper","state":"MERGED","url":"https://github.com/northstar/paper/pull/42","headRefOid":"saved-head","mergeable":"MERGEABLE","statusCheckRollup":[]}"#
                            .utf8)
                }
                if args.contains("diff") { return Data() }
                if args.contains(where: { $0.contains("git/ref") }) {
                    #expect(args.last?.hasSuffix("/heads/main") == true)
                    return Data(#"{"object":{"sha":"saved-head"}}"#.utf8)
                }
                #expect(args.contains("head_sha=saved-head"))
                return Data(
                    "{\"workflow_runs\":[{\"id\":71,\"path\":\"other.yml\",\"html_url\":\"https://example.com/other\",\"status\":\"completed\"},{\"id\":72,\"path\":\"\(project.workflowPath)\",\"html_url\":\"https://github.com/northstar/paper/actions/runs/72\",\"status\":\"completed\",\"conclusion\":\"success\"}]}"
                        .utf8)
            }
            let result = await CLIProbe.capture([
                "latex", "compile", project.id.uuidString, "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["status"] as? String == "queued")
            #expect(result.object?["buildID"] as? Int == 72)
            #expect(result.object?["pdfPath"] is NSNull)
            #expect(try LaTeXCLIEnvironment.store.load() == [project])
        }
    }
}

private actor LaTeXCLICalls {
    var values: [[String]] = []
    func record(_ args: [String]) { values.append(args) }
}
