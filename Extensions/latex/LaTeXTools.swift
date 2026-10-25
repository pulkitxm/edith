import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

private enum LaTeXTool: String, CaseIterable, Identifiable {
    case tectonic, latexmk, gh, pukbot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tectonic: "Tectonic"
        case .latexmk: "latexmk / TeX Live"
        case .gh: "GitHub CLI"
        case .pukbot: "Pukbot"
        }
    }
    var versionArguments: [String] { self == .latexmk ? ["-v"] : ["--version"] }
    var formula: String? {
        switch self {
        case .tectonic: "tectonic"
        case .latexmk: nil
        case .gh: "gh"
        case .pukbot: "pulkitxm/tap/pukbot"
        }
    }
    var why: String {
        switch self {
        case .tectonic: "Compiles local LaTeX sources into PDFs."
        case .latexmk:
            "Compiles pdfLaTeX documents, including sources with pdfTeX-specific commands."
        case .gh: "Lists the GitHub repositories you can reach and signs Code Stats clones in."
        case .pukbot: "Saves LaTeX source changes and manages GitHub pull requests."
        }
    }
    var instruction: String {
        switch self {
        case .tectonic: "Install with brew install tectonic."
        case .latexmk:
            "Install MacTeX from https://tug.org/mactex, then make /Library/TeX/texbin available on PATH."
        case .gh: "Install with `brew install gh`, then run `gh auth login`."
        case .pukbot: "Install with brew install pulkitxm/tap/pukbot."
        }
    }
}

@MainActor @Observable final class LaTeXToolOwner {
    typealias Run = @Sendable (String, [String]) async throws -> String
    private(set) var status: [String: String] = [:]
    private(set) var installed: Set<String> = []
    private(set) var busy: Set<String> = []
    private var jobs: [String: Task<Void, Never>] = [:]
    private var stopped = false
    private let remote: LaTeXUIBridge?
    private let run: Run

    init(
        remote: LaTeXUIBridge? = nil,
        run: @escaping Run = { tool, arguments in
            guard let executable = CLIToolEnvironment.executable(named: tool) else {
                throw LaTeXError.message("\(tool) is missing from PATH.")
            }
            let output = try await CLICommandRunner.runLocal(
                .init(
                    executableURL: executable, arguments: arguments,
                    environment: CLIToolEnvironment.sanitized(),
                    timeout: arguments.first == "install" ? 600 : 5,
                    maximumOutputBytes: 1_048_576, terminatesProcessGroup: true)
            ) { _ in }
            guard output.terminationStatus == 0 else {
                throw LaTeXError.message(String(output.output.suffix(4096)))
            }
            return output.output
        }
    ) { self.run = run; self.remote = remote }

    func refresh() {
        if let remote { remoteRequest(remote, action: "tools.refresh"); return }
        guard !stopped else { return }
        for tool in LaTeXTool.allCases where jobs[tool.id] == nil {
            start(tool, installing: false)
        }
    }

    func install(_ id: String) {
        if let remote { remoteRequest(remote, action: "tools.install", tool: id); return }
        guard !stopped, let tool = LaTeXTool(rawValue: id), jobs[id] == nil else { return }
        start(tool, installing: tool.formula != nil)
    }

    private func start(_ tool: LaTeXTool, installing: Bool) {
        busy.insert(tool.id)
        status[tool.id] = installing ? "Installing…" : "Checking availability…"
        jobs[tool.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.busy.remove(tool.id); self.jobs[tool.id] = nil }
            do {
                if installing, let formula = tool.formula {
                    _ = try await run("brew", ["install", formula])
                    try Task.checkCancellation()
                }
                let version = try await run(tool.id, tool.versionArguments)
                try Task.checkCancellation()
                guard !stopped else { return }
                installed.insert(tool.id)
                status[tool.id] =
                    "Installed, "
                    + String((version.split(separator: "\n").first ?? "verified").prefix(200))
            } catch {
                guard !stopped, !Task.isCancelled else { return }
                installed.remove(tool.id)
                status[tool.id] = String(error.localizedDescription.prefix(500))
            }
        }
    }

    var snapshot: LaTeXToolsSnapshot { .init(status: status, installed: installed, busy: busy) }
    func apply(_ snapshot: LaTeXToolsSnapshot) {
        guard !stopped else { return }
        status = snapshot.status; installed = snapshot.installed; busy = snapshot.busy
    }
    private func remoteRequest(_ remote: LaTeXUIBridge, action: String, tool: String? = nil) {
        guard !stopped, jobs[action] == nil else { return }
        jobs[action] = Task { [weak self] in
            defer { self?.jobs[action] = nil }
            do {
                let value = try await remote.perform(.init(action: action, tool: tool))
                try Task.checkCancellation()
                self?.apply(value.tools)
            } catch {
                if !Task.isCancelled { self?.status[tool ?? "tools"] = error.localizedDescription }
            }
        }
    }
    func shutdown() async {
        stopped = true
        let pending = Array(jobs.values)
        for job in pending { job.cancel() }
        for job in pending { await job.value }
        jobs.removeAll(); busy.removeAll(); status.removeAll(); installed.removeAll()
    }
}

struct LaTeXSettings: View {
    let owner: LaTeXToolOwner

    var body: some View {
        Form {
            Section("LaTeX projects") {
                Text("Add local .tex files or GitHub repositories from the LaTeX page.")
                    .font(.edithText(.body))
                Text(
                    "Local compilation uses Tectonic or a TeX Live installation. Repository projects use GitHub Actions for PDFs, Quinjet for review, and Pukbot for pull request changes and squash merges."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            Section {
                ForEach(LaTeXTool.allCases) { tool in
                    HStack(alignment: .top, spacing: UIScale.pt(10)) {
                        icon(tool).frame(width: UIScale.pt(18), height: UIScale.pt(22))
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(tool.title).fontWeight(.medium)
                            if owner.busy.contains(tool.id) {
                                SkeletonGroup { SkeletonBlock(width: 150, height: 8) }
                                    .accessibilityLabel(detail(tool))
                            } else {
                                Text(detail(tool)).font(.edithText(.caption))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 12)
                        if canInstall(tool) {
                            Button(failed(tool) ? "Retry" : "Install") { owner.install(tool.id) }
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Tools stay installed when the extension is disabled.")
            }
        }
        .edithForm()
        .pageTask { owner.refresh() }
    }

    private func failed(_ tool: LaTeXTool) -> Bool {
        !owner.installed.contains(tool.id) && !owner.busy.contains(tool.id)
            && owner.status[tool.id] != nil
    }

    private func canInstall(_ tool: LaTeXTool) -> Bool {
        !owner.installed.contains(tool.id) && !owner.busy.contains(tool.id)
    }

    private func detail(_ tool: LaTeXTool) -> String {
        if owner.installed.contains(tool.id) || owner.busy.contains(tool.id) {
            return owner.status[tool.id] ?? tool.why
        }
        guard let status = owner.status[tool.id] else { return tool.why }
        return "\(status). \(tool.instruction)"
    }

    @ViewBuilder private func icon(_ tool: LaTeXTool) -> some View {
        if owner.busy.contains(tool.id) {
            SkeletonGroup { SkeletonBlock(width: 14, height: 14, corner: 7) }
                .accessibilityLabel("Checking command-line tool")
        } else if owner.installed.contains(tool.id) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if owner.status[tool.id] != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}
