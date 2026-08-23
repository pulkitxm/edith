import AppKit
import EdithCore
import Foundation

public enum UsageProjectOperation: String, CaseIterable, Sendable {
    case list
    case show
    case openRepository
    case copyRepositoryLink
    case copyChatID

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list:
            descriptor("list", "List usage grouped by repository.", effect: .read)
        case .show:
            descriptor("show", "Show one repository and its folders.", effect: .read)
        case .openRepository:
            descriptor("open", "Open a usage repository in the browser.", effect: .interactive)
        case .copyRepositoryLink:
            descriptor("copy-link", "Copy a usage repository link.", effect: .write)
        case .copyChatID:
            descriptor("copy-chat", "Copy a usage chat identifier.", effect: .write)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "usage.projects.\(rawValue)"), summary: summary,
            cli: ["usage", "projects", verb], effect: effect)
    }
}

public struct UsageProjectTarget: Equatable, Sendable {
    public let repositoryID: String
    public let repositoryName: String
    public let repositoryURL: String?

    public init(repositoryID: String, repositoryName: String, repositoryURL: String?) {
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.repositoryURL = repositoryURL
    }
}

public enum UsageProjectOperationError: Error, Equatable, LocalizedError {
    case emptyQuery
    case projectNotFound(String)
    case projectAmbiguous(String, [String])
    case repositoryLinkUnavailable(String)
    case invalidRepositoryLink(String)
    case emptyChatID
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyQuery:
            "A repository name or identity is required."
        case let .projectNotFound(query):
            "No usage repository matches \(query)."
        case let .projectAmbiguous(query, matches):
            "Usage repository \(query) is ambiguous: \(matches.joined(separator: ", "))."
        case let .repositoryLinkUnavailable(name):
            "\(name) has no repository link."
        case let .invalidRepositoryLink(value):
            "\(value) is not a valid HTTP repository link."
        case .emptyChatID:
            "A chat identifier is required."
        case let .actionFailed(action):
            "Could not \(action)."
        }
    }
}

public struct UsageProjectOperationResult: Equatable, Sendable {
    public let operationID: UserOperationID
    public let repositoryID: String?
    public let value: String

    public init(operationID: UserOperationID, repositoryID: String?, value: String) {
        self.operationID = operationID
        self.repositoryID = repositoryID
        self.value = value
    }
}

public enum UsageProjectOperationExecution {
    public static func resolve(
        _ query: String, in projects: [UsageProjectTarget]
    ) throws -> UsageProjectTarget {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw UsageProjectOperationError.emptyQuery }
        let normalizedNeedle = normalized(needle)
        let matches = projects.filter { project in
            normalized(project.repositoryID) == normalizedNeedle
                || normalized(project.repositoryName) == normalizedNeedle
                || project.repositoryURL.map(normalized) == normalizedNeedle
        }
        guard !matches.isEmpty else {
            throw UsageProjectOperationError.projectNotFound(needle)
        }
        guard matches.count == 1 else {
            throw UsageProjectOperationError.projectAmbiguous(
                needle, matches.map(\.repositoryID).sorted())
        }
        return matches[0]
    }

    public static func repositoryURL(for target: UsageProjectTarget) throws -> URL {
        guard let raw = target.repositoryURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            throw UsageProjectOperationError.repositoryLinkUnavailable(target.repositoryName)
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme), url.host != nil
        else {
            throw UsageProjectOperationError.invalidRepositoryLink(raw)
        }
        return url
    }

    public static func openRepository(
        _ target: UsageProjectTarget, using opener: (URL) -> Bool
    ) throws -> UsageProjectOperationResult {
        let url = try repositoryURL(for: target)
        guard opener(url) else {
            throw UsageProjectOperationError.actionFailed("open \(target.repositoryName)")
        }
        return UsageProjectOperationResult(
            operationID: UsageProjectOperation.openRepository.descriptor.id,
            repositoryID: target.repositoryID, value: url.absoluteString)
    }

    @MainActor
    public static func openRepository(
        _ target: UsageProjectTarget
    ) throws -> UsageProjectOperationResult {
        try openRepository(target) { NSWorkspace.shared.open($0) }
    }

    public static func copyRepositoryLink(
        _ target: UsageProjectTarget, using copier: (String) -> Bool
    ) throws -> UsageProjectOperationResult {
        let link = try repositoryURL(for: target).absoluteString
        guard copier(link) else {
            throw UsageProjectOperationError.actionFailed(
                "copy the link for \(target.repositoryName)")
        }
        return UsageProjectOperationResult(
            operationID: UsageProjectOperation.copyRepositoryLink.descriptor.id,
            repositoryID: target.repositoryID, value: link)
    }

    @MainActor
    public static func copyRepositoryLink(
        _ target: UsageProjectTarget
    ) throws -> UsageProjectOperationResult {
        try copyRepositoryLink(target) { value in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(value, forType: .string)
        }
    }

    public static func copyChatID(
        _ chatID: String, using copier: (String) -> Bool
    ) throws -> UsageProjectOperationResult {
        let value = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw UsageProjectOperationError.emptyChatID }
        guard copier(value) else {
            throw UsageProjectOperationError.actionFailed("copy the chat identifier")
        }
        return UsageProjectOperationResult(
            operationID: UsageProjectOperation.copyChatID.descriptor.id,
            repositoryID: nil, value: value)
    }

    @MainActor
    public static func copyChatID(_ chatID: String) throws -> UsageProjectOperationResult {
        try copyChatID(chatID) { value in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(value, forType: .string)
        }
    }

    private static func normalized(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        if normalized.hasSuffix(".git") { normalized.removeLast(4) }
        return normalized
    }
}
