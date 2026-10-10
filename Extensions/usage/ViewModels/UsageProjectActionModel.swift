import Foundation
import Observation

@MainActor
@Observable
final class UsageProjectActionModel {
    private(set) var failureMessage: String?
    private var operation: Task<Void, Never>?
    var client: UsageUIClient?

    func cancel() { operation?.cancel(); operation = nil }

    private let openRepositoryAction:
        @MainActor (UsageProjectTarget) throws -> UsageProjectOperationResult
    private let copyRepositoryLinkAction:
        @MainActor (UsageProjectTarget) throws -> UsageProjectOperationResult
    private let copyChatIDAction: @MainActor (String) throws -> UsageProjectOperationResult

    init(
        openRepository:
            @escaping @MainActor (UsageProjectTarget) throws ->
            UsageProjectOperationResult = { try UsageProjectOperationExecution.openRepository($0) },
        copyRepositoryLink:
            @escaping @MainActor (UsageProjectTarget) throws ->
            UsageProjectOperationResult = {
                try UsageProjectOperationExecution.copyRepositoryLink($0)
            },
        copyChatID: @escaping @MainActor (String) throws -> UsageProjectOperationResult = {
            try UsageProjectOperationExecution.copyChatID($0)
        }
    ) {
        openRepositoryAction = openRepository
        copyRepositoryLinkAction = copyRepositoryLink
        copyChatIDAction = copyChatID
    }

    func openRepository(_ target: UsageProjectTarget) {
        if remote("usage.ui.project.open", key: "repositoryID", value: target.repositoryID) {
            return
        }
        perform { try openRepositoryAction(target) }
    }

    func copyRepositoryLink(_ target: UsageProjectTarget) {
        if remote("usage.ui.project.copy", key: "repositoryID", value: target.repositoryID) {
            return
        }
        perform { try copyRepositoryLinkAction(target) }
    }

    func copyChatID(_ chatID: String) {
        if remote("usage.ui.chat.copy", key: "chatID", value: chatID) { return }
        perform { try copyChatIDAction(chatID) }
    }

    func dismissFailure() {
        failureMessage = nil
    }

    private func remote(_ command: String, key: String, value: String) -> Bool {
        guard let client = client ?? UsageUIClient.current else { return false }
        operation?.cancel()
        operation = Task { [weak self] in
            do {
                _ = try await client.value(command, object: [key: value], as: String.self)
                guard !Task.isCancelled, !client.stopped else { return }
                self?.failureMessage = nil
            } catch {
                guard !Task.isCancelled, !client.stopped else { return }
                self?.failureMessage = error.localizedDescription + " Try again."
            }
        }
        return true
    }

    private func perform(_ action: () throws -> UsageProjectOperationResult) {
        do {
            _ = try action()
            failureMessage = nil
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else {
                failureMessage = "The project action failed. Try again."
                return
            }
            failureMessage =
                detail.hasSuffix(".") ? "\(detail) Try again." : "\(detail). Try again."
        }
    }
}
