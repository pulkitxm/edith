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
    var instruction: String {
        switch self {
        case .tectonic: "Compiles local LaTeX sources into PDFs."
        case .latexmk: "Install MacTeX and add /Library/TeX/texbin to PATH."
        case .gh: "Reads repository source and PDF artifacts. Sign in with gh auth login."
        case .pukbot: "Saves repository changes and manages pull requests."
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
        guard !stopped, let tool = LaTeXTool(rawValue: id), tool.formula != nil,
            jobs[id] == nil
        else { return }
        start(tool, installing: true)
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

struct LaTeXToolsPage: View {
    let owner: LaTeXToolOwner
    var body: some View {
        PageScaffold(width: .readable) {
            PageHeader(
                "LaTeX tools",
                trailing: {
                    Button("Check again") { owner.refresh() }.disabled(!owner.busy.isEmpty)
                })
        } content: {
            ForEach(LaTeXTool.allCases) { tool in
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    if owner.busy.contains(tool.id) {
                        LoadingIndicator()
                    } else {
                        Image(
                            systemName: owner.installed.contains(tool.id)
                                ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .foregroundStyle(owner.installed.contains(tool.id) ? .green : .secondary)
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        Text(tool.title).font(.edithText(.headline))
                        Text(owner.status[tool.id] ?? "Not checked").font(.edithText(.caption))
                        Text(tool.instruction).font(.edithText(.caption)).foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    if !owner.installed.contains(tool.id) {
                        if tool.formula != nil {
                            Button("Install") { owner.install(tool.id) }
                                .disabled(owner.busy.contains(tool.id))
                        } else {
                            Link("Get MacTeX", destination: URL(string: "https://tug.org/mactex/")!)
                        }
                    }
                }.padding(.vertical, UIScale.pt(8))
            }
            Text(
                "Tools already installed on this Mac stay available when this extension is disabled."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
        }.pageTask { owner.refresh() }
    }
}
