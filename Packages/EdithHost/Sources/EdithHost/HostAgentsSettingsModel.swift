import EdithExtensionUI
import EdithHostCore
import Foundation
import Observation

struct HostAgentResult: Equatable {
    let succeeded: Bool
    let message: String
    var snippet: String?

    static func connecting(_ outcome: HostMCPInstaller.Outcome) -> Self? {
        switch outcome.action {
        case .created, .updated:
            guard outcome.applied else { return nil }
            return Self(succeeded: true, message: "Connected. Restart the agent to load Edith.")
        case .unchanged:
            return Self(succeeded: true, message: "Already connected.")
        case .manual:
            return Self(
                succeeded: false,
                message: (outcome.note ?? "Edith could not do this step.")
                    + " Run this in a terminal:",
                snippet: outcome.runLine)
        case .skipped:
            if let run = outcome.runLine, !outcome.client.editsFileWithoutTool {
                return Self(
                    succeeded: false,
                    message: (outcome.note ?? "Not connected.") + " Run it yourself:", snippet: run)
            }
            return Self(
                succeeded: false,
                message: (outcome.note ?? "Not connected.") + " Add this entry yourself:",
                snippet: outcome.snippet.trimmingCharacters(in: .newlines))
        case .removed, .notFound:
            return nil
        }
    }

    static func disconnecting(_ outcome: HostMCPInstaller.Outcome, path: String) -> Self? {
        switch outcome.action {
        case .removed:
            guard outcome.applied else { return nil }
            return Self(
                succeeded: true, message: "Disconnected. Restart the agent to unload Edith.")
        case .unchanged:
            return Self(succeeded: true, message: "Edith was not connected.")
        case .manual:
            return Self(
                succeeded: false,
                message: (outcome.note ?? "Edith could not do this step.")
                    + " Run this in a terminal:",
                snippet: outcome.runLine)
        case .skipped:
            if let run = outcome.runLine, !outcome.client.editsFileWithoutTool {
                return Self(
                    succeeded: false,
                    message: (outcome.note ?? "Not disconnected.") + " Run it yourself:",
                    snippet: run)
            }
            return Self(
                succeeded: false,
                message: (outcome.note ?? "Not disconnected.")
                    + " Delete the edith entry from \(path) yourself."
            )
        case .created, .updated, .notFound:
            return nil
        }
    }
}

@MainActor @Observable final class HostAgentsSettingsModel {
    enum Operation: Equatable {
        case connect(HostMCPClient)
        case connectAll
        case disconnect(HostMCPClient)
    }

    let load = ContentLoad()
    let installer: HostMCPInstaller
    private let defaults: UserDefaults
    private let copy: (String) -> Void
    private var work: Task<Void, Never>?
    private(set) var reports: [HostMCPInstaller.Report] = []
    private(set) var running: Operation?
    private(set) var results: [HostMCPClient: HostAgentResult] = [:]
    private(set) var copied: String?

    init(installer: HostMCPInstaller, defaults: UserDefaults, copy: @escaping (String) -> Void) {
        self.installer = installer
        self.defaults = defaults
        self.copy = copy
    }

    var pending: [HostMCPInstaller.Report] {
        reports.filter { $0.clientFound && $0.connection != .connected }
    }

    var canConnectAll: Bool {
        running == nil && pending.contains { $0.connection != .manual }
    }

    func guidance(_ report: HostMCPInstaller.Report) -> HostAgentResult? {
        guard report.connection == .otherEdith else { return manualStep(report) }
        let current = report.command.map { "runs \(display($0))" } ?? "runs a different command"
        return HostAgentResult(
            succeeded: false,
            message:
                "The edith entry \(current). Connect replaces it with this Edith.")
    }

    func manualStep(_ report: HostMCPInstaller.Report) -> HostAgentResult? {
        guard report.connection == .manual else { return nil }
        if report.state == .unreadable {
            return HostAgentResult(
                succeeded: false,
                message:
                    "\(display(report.path)) could not be read safely, so Edith leaves it alone. Add this entry yourself:",
                snippet: installer.manualStep(report.client).trimmingCharacters(in: .newlines))
        }
        return HostAgentResult(
            succeeded: false,
            message:
                "The \(report.client.registrationTool ?? report.client.rawValue) command was not found on this Mac. Once \(report.client.title) is installed, run:",
            snippet: installer.manualStep(report.client))
    }

    func refresh() async {
        let installer = installer
        await load.perform(operation: { installer.status() }) { reports in
            self.reports = reports
            if reports.contains(where: { $0.connection == .connected }) {
                self.defaults.set(true, forKey: HostSettingsCatalog.getStartedAgentKey)
            }
        }
    }

    func run(_ operation: Operation) {
        guard running == nil else { return }
        work = Task { await perform(operation) }
    }

    func perform(_ operation: Operation) async {
        guard running == nil else { return }
        running = operation
        copied = nil
        let installer = installer
        let outcomes = await Task.detached(priority: .userInitiated) {
            switch operation {
            case .connect(let client): installer.install([client], dryRun: false)
            case .connectAll: installer.install(nil, dryRun: false)
            case .disconnect(let client): installer.uninstall([client], dryRun: false)
            }
        }.value
        for outcome in outcomes {
            let result =
                if case .disconnect = operation {
                    HostAgentResult.disconnecting(outcome, path: display(outcome.path))
                } else {
                    HostAgentResult.connecting(outcome)
                }
            if let result { results[outcome.client] = result }
        }
        running = nil
        await refresh()
    }

    func copySnippet(_ snippet: String) {
        copy(snippet)
        copied = snippet
    }

    func cancel() {
        load.cancel()
    }

    func display(_ path: String) -> String {
        let home =
            installer.home.path.hasSuffix("/") ? installer.home.path : installer.home.path + "/"
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }
}
