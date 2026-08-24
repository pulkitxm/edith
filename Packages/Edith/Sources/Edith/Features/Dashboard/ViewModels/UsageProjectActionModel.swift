import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class UsageProjectActionModel {
    private(set) var failureMessage: String?

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
        perform { try openRepositoryAction(target) }
    }

    func copyRepositoryLink(_ target: UsageProjectTarget) {
        perform { try copyRepositoryLinkAction(target) }
    }

    func copyChatID(_ chatID: String) {
        perform { try copyChatIDAction(chatID) }
    }

    func dismissFailure() {
        failureMessage = nil
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
