import Foundation

public struct LaTeXService: Sendable {
    public typealias Execute = @Sendable (String, [String], Data?, URL?) async throws -> Data
    private let execute: Execute

    public init(execute: @escaping Execute) { self.execute = execute }

    public static let live = LaTeXService { tool, arguments, input, directory in
        guard let executable = CLIToolEnvironment.executable(named: tool) else {
            throw LaTeXError.message("\(tool) is missing. Install it in Extensions, then retry.")
        }
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: executable, arguments: arguments,
                environment: CLIToolEnvironment.sanitized(), currentDirectoryURL: directory,
                timeout: tool == "tectonic" ? 300 : 60, maximumOutputBytes: 4_194_304,
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
            "tectonic",
            [
                "-X", "compile", "--untrusted", "--keep-logs", "--outdir",
                source.deletingLastPathComponent().path, source.path,
            ], directory: source.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: project.pdfURL.path) else {
            throw LaTeXError.message("Compilation finished without producing a PDF.")
        }
        return String(decoding: output, as: UTF8.self)
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
        if let number = project.pullRequest { return number }
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
        let arguments = [String(number), "--repo", project.repository, "--refresh", "--json"]
        let metadata = try await run("quinjet", ["pr", "view"] + arguments)
        let pr = try JSONDecoder().decode(ReviewSnapshot.self, from: metadata).pullRequest
        let diff = try await run("quinjet", ["pr", "diff"] + arguments.filter { $0 != "--json" })
        let checks = try await run("quinjet", ["pr", "checks"] + arguments)
        return LaTeXReview(
            pullRequest: pr, diff: String(decoding: diff, as: UTF8.self),
            checks: try JSONDecoder().decode(CheckSnapshot.self, from: checks).checks)
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
                  - uses: actions/upload-artifact@v4
                    with:
                      name: latex-\(project.id.uuidString.lowercased())
                      path: ${{ runner.temp }}/latex-output/*.pdf
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

    private struct ReviewSnapshot: Decodable { let pullRequest: LaTeXPullRequest }
    private struct CheckSnapshot: Decodable { let checks: [LaTeXCheck] }
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
