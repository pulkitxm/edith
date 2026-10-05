import EdithCore
import Foundation

public enum CodeStatsOperation: String, CaseIterable, Sendable {
    case status
    case run
    case cancel
    case report
    case folder
    case schedule
    case identityAdd
    case identityRemove
    case identityList
    case authors
    case audit
    case export

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "codeStats." + command.joined(separator: ".")),
            summary: summary, cli: ["code-stats"] + command, effect: effect)
    }

    private var command: [String] {
        switch self {
        case .identityAdd: ["identity", "add"]
        case .identityRemove: ["identity", "remove"]
        case .identityList: ["identity", "list"]
        default: [rawValue]
        }
    }

    private var summary: String {
        switch self {
        case .status: "Show the mirror folder, schedule, last refresh and live progress."
        case .run: "Refresh the mirror and recount your commits."
        case .cancel: "Cancel the refresh in progress."
        case .report: "Print the code stats report for a range."
        case .folder: "Choose the folder that holds the repository mirror."
        case .schedule: "Choose how often code stats refresh on their own."
        case .identityAdd: "Count commits with this email or name fragment as yours."
        case .identityRemove: "Stop counting commits with this email or name fragment."
        case .identityList: "List the emails and name fragments counted as you."
        case .authors: "List the commit authors found in the mirror."
        case .audit: "Explain what was counted and what was excluded, and why."
        case .export: "Render the code stats as PNG metric cards."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .status, .report, .identityList, .authors, .audit: .read
        case .run, .cancel, .folder, .schedule, .identityAdd, .identityRemove, .export: .write
        }
    }
}
