import Foundation
import ZIPFoundation

public struct LaTeXService: Sendable {
    public typealias Execute = @Sendable (String, [String], Data?, URL?) async throws -> Data
    private let execute: Execute

    public init(execute: @escaping Execute) { self.execute = execute }

    public static let live = LaTeXService { tool, arguments, input, directory in
        guard let executable = CLIToolEnvironment.executable(named: tool) else {
            throw LaTeXError.message("\(tool) is missing. Install it in Extensions, then retry.")
        }
        let result = try await CLICommandRunner.runLocal(
            CLICommandRequest(
                executableURL: executable, arguments: arguments,
                environment: CLIToolEnvironment.sanitized(), currentDirectoryURL: directory,
                timeout: ["tectonic", "latexmk", "pukbot"].contains(tool) ? 300 : 60,
                maximumOutputBytes: 20_971_520,
                standardInputData: input, terminatesProcessGroup: true)
        ) { _ in }
        guard result.terminationStatus == 0 else {
            throw LaTeXError.message(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.standardOutputData
    }

    public func resolve(_ project: LaTeXProject) async throws -> LaTeXProject {
        var project = project
        if project.location == .github {
            guard LaTeXProject.validRepository(project.repository) else {
                throw LaTeXError.message("Enter a GitHub repository as owner/repository.")
            }
            if project.baseBranch.isEmpty {
                let data = try await run("gh", ["api", "repos/\(project.repository)"])
                project.baseBranch = try JSONDecoder().decode(Repository.self, from: data)
                    .default_branch
            }
        }
        try project.validate()
        return project
    }

    public func load(_ project: LaTeXProject) async throws -> LaTeXSource {
        try project.validate()
        if project.location == .disk {
            let data = try Data(contentsOf: URL(fileURLWithPath: project.sourcePath))
            guard let text = String(data: data, encoding: .utf8) else {
                throw LaTeXError.message("The source file must be UTF-8 text.")
            }
            return LaTeXSource(text: text, revision: data.base64EncodedString())
        }
        let base = try await branchSHA(project, branch: project.baseBranch)
        var ref = base
        if let branch = project.reviewBranch {
            do { ref = try await branchSHA(project, branch: branch) } catch let error as LaTeXError
            {
                guard error.localizedDescription.contains("404"), project.pullRequest == nil else {
                    throw error
                }
            }
        }
        let data = try await run(
            "gh",
            [
                "api", "--method", "GET",
                "repos/\(project.repository)/contents/\(encodedPath(project.sourcePath))",
                "-f", "ref=\(ref)",
            ])
        let file = try JSONDecoder().decode(SourceFile.self, from: data)
        guard file.type == "file", file.encoding == "base64",
            let bytes = Data(base64Encoded: file.content, options: .ignoreUnknownCharacters),
            let text = String(data: bytes, encoding: .utf8)
        else { throw LaTeXError.message("GitHub did not return a UTF-8 source file.") }
        return LaTeXSource(text: text, revision: file.sha, baseCommit: base)
    }

    public func saveLocal(_ project: LaTeXProject, text: String, original: LaTeXSource) throws {
        guard project.location == .disk else {
            throw LaTeXError.message("Use a pull request for this project.")
        }
        let url = URL(fileURLWithPath: project.sourcePath)
        let current = try Data(contentsOf: url)
        guard current.base64EncodedString() == original.revision else {
            throw LaTeXError.message(
                "The source changed on disk. Copy your edits, then reload before saving.")
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public func compileLocal(_ project: LaTeXProject) async throws -> String {
        try project.validate()
        guard project.location == .disk else {
            throw LaTeXError.message("Repository builds run on GitHub.")
        }
        let source = URL(fileURLWithPath: project.sourcePath)
        let output = try await run(
            project.compiler == .tectonic ? "tectonic" : "latexmk",
            project.compiler == .tectonic
                ? [
                    "-X", "compile", "--untrusted", "--keep-logs", "--outdir",
                    source.deletingLastPathComponent().path, source.path,
                ]
                : [
                    "-norc", "-pdf", "-no-shell-escape", "-file-line-error", "-halt-on-error",
                    "-interaction=nonstopmode", source.path,
                ], directory: source.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: project.pdfURL.path) else {
            throw LaTeXError.message("Compilation finished without producing a PDF.")
        }
        return String(decoding: output, as: UTF8.self)
    }

    public func build(_ project: LaTeXProject) async throws -> LaTeXBuild? {
        try project.validate()
        guard project.location == .github else {
            throw LaTeXError.message("Local builds run on this Mac.")
        }
        let sha = try await branchSHA(project, branch: project.reviewBranch ?? project.baseBranch)
        let data = try await run(
            "gh",
            [
                "api", "--method", "GET", "repos/\(project.repository)/actions/runs",
                "-f", "head_sha=\(sha)", "-f", "per_page=100",
            ])
        return try JSONDecoder().decode(Builds.self, from: data).workflow_runs.first {
            $0.path == project.workflowPath
        }
    }

    public func rebuild(_ project: LaTeXProject) async throws -> LaTeXBuild {
        guard var build = try await build(project) else {
            throw LaTeXError.message(
                "No PDF build exists for this revision. Save to a pull request first.")
        }
        if build.status == "completed" {
            _ = try await run(
                "pukbot",
                [
                    "workflow", "rerun", "--repo", project.repository, String(build.id), "--json",
                ])
            build.status = "queued"
            build.conclusion = nil
        }
        return build
    }

    private struct Builds: Decodable { let workflow_runs: [LaTeXBuild] }

    public func previewPDF(_ project: LaTeXProject, buildID: Int? = nil) async throws -> Data? {
        try project.validate()
        guard project.location == .github else {
            throw LaTeXError.message("Local PDFs are read from disk.")
        }
        let sha = try await branchSHA(project, branch: project.reviewBranch ?? project.baseBranch)
        let response = try await run(
            "gh",
            [
                "api", "--method", "GET", "repos/\(project.repository)/actions/artifacts", "-f",
                "name=latex-\(project.id.uuidString.lowercased())", "-f", "per_page=100",
            ])
        let artifacts = try JSONDecoder().decode(Artifacts.self, from: response).artifacts
        guard
            let artifact = artifacts.first(where: {
                !$0.expired && $0.workflow_run.head_sha == sha
                    && (buildID == nil || $0.workflow_run.id == buildID)
            })
        else { return nil }
        let limit = 20_971_520
        guard artifact.size_in_bytes <= limit else {
            throw LaTeXError.message(
                "This PDF is too large to preview. Open the artifact on GitHub.")
        }
        let bytes = try await run(
            "gh", ["api", "repos/\(project.repository)/actions/artifacts/\(artifact.id)/zip"])
        let archive = try Archive(data: bytes, accessMode: .read)
        guard
            let entry = archive.first(where: {
                $0.type == .file
                    && URL(fileURLWithPath: $0.path).lastPathComponent
                        == project.pdfURL.lastPathComponent
            }), entry.uncompressedSize <= limit
        else { throw LaTeXError.message("The build artifact does not contain the expected PDF.") }
        var pdf = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard pdf.count + chunk.count <= limit else {
                throw LaTeXError.message("The PDF exceeds the preview limit.")
            }
            pdf.append(chunk)
        }
        guard checksum == entry.checksum, pdf.starts(with: Data("%PDF-".utf8)) else {
            throw LaTeXError.message("The PDF artifact is damaged. Rebuild it on GitHub.")
        }
        return pdf
    }

    private struct Artifacts: Decodable {
        let artifacts: [Artifact]
        struct Artifact: Decodable {
            let id: Int
            let expired: Bool
            let size_in_bytes: Int
            let workflow_run: Run
            struct Run: Decodable {
                let id: Int?
                let head_sha: String
            }
        }
    }

    public func submit(_ project: LaTeXProject, text: String, original: LaTeXSource) async throws
        -> Int
    {
        try project.validate()
        guard project.location == .github, let branch = project.reviewBranch else {
            throw LaTeXError.message("Prepare a review branch before submitting.")
        }
        if project.pullRequest == nil {
            do {
                _ = try await branchSHA(project, branch: branch)
            } catch let error as LaTeXError {
                guard error.localizedDescription.contains("404") else { throw error }
                _ = try await run(
                    "pukbot",
                    [
                        "ref", "create", "--repo", project.repository, "--sha", original.baseCommit,
                        "refs/heads/\(branch)", "--json",
                    ])
            }
        }
        var review = project
        review.reviewBranch = branch
        let current = try await load(review)
        guard current.revision == original.revision || current.text == text else {
            throw LaTeXError.message(
                "The source changed on GitHub. Copy your edits, then reload before submitting.")
        }
        if current.text != text || project.pullRequest == nil {
            let document = CommitDocument(
                repository: project.repository, branch: branch,
                message: "Update \(project.sourcePath) and compile PDF",
                files: [
                    CommitFile(path: project.sourcePath, content: text),
                    CommitFile(path: project.workflowPath, content: Self.workflow(project)),
                ])
            _ = try await run(
                "pukbot", ["apply", "--input", "-", "--json"], input: JSONEncoder().encode(document)
            )
        }
        if let number = project.pullRequest {
            if current.text == text { _ = try await rebuild(project) }
            return number
        }
        let existing = try await pullRequests(project, branch: branch)
        if let number = existing.first?.number { return number }
        _ = try await run(
            "pukbot",
            [
                "pr", "create", "--repo", project.repository, "--head", branch, "--base",
                project.baseBranch,
                "--title", "Compile \(project.name)", "--body",
                "Update the LaTeX source and build its PDF on GitHub.", "--json",
            ])
        guard let number = try await pullRequests(project, branch: branch).first?.number else {
            throw LaTeXError.message(
                "The branch is saved on GitHub. Retry to reconnect its pull request.")
        }
        return number
    }

    public func review(_ project: LaTeXProject) async throws -> LaTeXReview {
        guard let number = project.pullRequest else {
            throw LaTeXError.message("Create a pull request first.")
        }
        let arguments = [String(number), "--repo", project.repository]
        let metadata = try await run(
            "gh",
            ["pr", "view"] + arguments + [
                "--json",
                "number,title,state,url,headRefOid,mergeable,statusCheckRollup",
            ])
        let snapshot = try JSONDecoder().decode(GitHubReview.self, from: metadata)
        let diff = try await run("gh", ["pr", "diff"] + arguments)
        return LaTeXReview(
            pullRequest: LaTeXPullRequest(
                number: snapshot.number, title: snapshot.title,
                state: snapshot.state, url: snapshot.url, headOid: snapshot.headRefOid,
                mergeable: snapshot.mergeable),
            diff: String(decoding: diff, as: UTF8.self),
            checks: snapshot.statusCheckRollup.map { $0.check })
    }

    public func merge(_ project: LaTeXProject, automatically: Bool) async throws {
        guard let number = project.pullRequest else {
            throw LaTeXError.message("Create a pull request first.")
        }
        _ = try await run(
            "pukbot",
            [
                "pr", "merge", "--repo", project.repository, String(number),
                "--delete-branch", automatically ? "--auto" : "--yes", "--json",
            ])
    }

    public static func workflow(_ project: LaTeXProject) -> String {
        let source = project.sourcePath.replacingOccurrences(of: "'", with: "''")
        let compile: String
        let artifact: String
        if project.compiler == .pdfLatex {
            compile = """
                - uses: xu-cheng/latex-action@v4
                  with:
                    root_file: '\(source)'
                    work_in_root_file_dir: true
                    args: '-norc -pdf -no-shell-escape -file-line-error -halt-on-error -interaction=nonstopmode'
                """
            artifact = "'\(String(source.dropLast(4))).pdf'"
        } else {
            compile = """
                - uses: wtfjoke/setup-tectonic@v3
                  with:
                    github-token: ${{ secrets.GITHUB_TOKEN }}
                - name: Compile PDF
                  env:
                    TEX_SOURCE: '\(source)'
                  run: |
                    mkdir -p "$RUNNER_TEMP/latex-output"
                    cd "$(dirname "$TEX_SOURCE")"
                    tectonic -X compile --untrusted --keep-logs --outdir "$RUNNER_TEMP/latex-output" "$(basename "$TEX_SOURCE")"
                """
            artifact = "${{ runner.temp }}/latex-output/*.pdf"
        }
        let steps = compile.split(separator: "\n", omittingEmptySubsequences: false).map {
            "      " + $0
        }.joined(separator: "\n")
        return """
            name: LaTeX PDF
            on:
              pull_request:
              push:
              workflow_dispatch:
            permissions:
              contents: read
            jobs:
              compile:
                runs-on: ubuntu-latest
                timeout-minutes: 10
                steps:
                  - uses: actions/checkout@v4
            \(steps)
                  - uses: actions/upload-artifact@v4
                    with:
                      name: latex-\(project.id.uuidString.lowercased())
                      path: \(artifact)
                      if-no-files-found: error
            """ + "\n"
    }

    private func branchSHA(_ project: LaTeXProject, branch: String) async throws -> String {
        let data = try await run(
            "gh", ["api", "repos/\(project.repository)/git/ref/heads/\(encodedPath(branch))"])
        return try JSONDecoder().decode(Branch.self, from: data).object.sha
    }

    private func pullRequests(_ project: LaTeXProject, branch: String) async throws -> [PullNumber]
    {
        let owner = project.repository.split(separator: "/")[0]
        let data = try await run(
            "gh",
            [
                "api", "--method", "GET", "repos/\(project.repository)/pulls", "-f", "state=open",
                "-f", "head=\(owner):\(branch)", "-f", "base=\(project.baseBranch)",
            ])
        return try JSONDecoder().decode([PullNumber].self, from: data)
    }

    private func run(
        _ tool: String, _ arguments: [String], input: Data? = nil, directory: URL? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        return try await execute(tool, arguments, input, directory)
    }

    private func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        )!
    }

    private struct GitHubReview: Decodable {
        let number: Int
        let title, state, url, headRefOid, mergeable: String
        let statusCheckRollup: [GitHubCheck]
    }

    private struct GitHubCheck: Decodable {
        let name, context, workflowName, status, conclusion, state, detailsUrl, targetUrl: String?
        var check: LaTeXCheck {
            let outcome = (conclusion ?? state ?? status ?? "pending").lowercased()
            let status: String
            switch outcome {
            case "success": status = "passed"
            case "failure", "error", "timed_out", "cancelled", "action_required", "startup_failure":
                status = "failed"
            case "neutral", "skipped": status = "skipped"
            default: status = "pending"
            }
            return LaTeXCheck(
                name: name ?? context ?? "Check", workflow: workflowName ?? "GitHub",
                status: status, link: detailsUrl ?? targetUrl ?? "")
        }
    }
    private struct Repository: Decodable { let default_branch: String }
    private struct Branch: Decodable {
        struct Object: Decodable { let sha: String }
        let object: Object
    }
    private struct SourceFile: Decodable {
        let type: String
        let encoding: String
        let content: String
        let sha: String
    }
    private struct PullNumber: Decodable { let number: Int }
    private struct CommitFile: Encodable { let path: String; let content: String }
    private struct CommitDocument: Encodable {
        let operation = "commit_create"
        let repository: String
        let branch: String
        let message: String
        let files: [CommitFile]
    }
}

public struct LaTeXPullRequest: Decodable, Sendable {
    public let number: Int
    public let title: String
    public let state: String
    public let url: String
    public let headOid: String
    public let mergeable: String
}

public struct LaTeXReview: Sendable {
    public let pullRequest: LaTeXPullRequest
    public let diff: String
    public let checks: [LaTeXCheck]
}

public struct LaTeXCheck: Decodable, Sendable {
    public let name: String
    public let workflow: String
    public let status: String
    public let link: String
}

public struct LaTeXBuild: Decodable, Sendable {
    public let id: Int
    public let path: String
    public let html_url: String
    public var status: String
    public var conclusion: String?
}
