import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageProjectOperationTests {
    static let alpha = UsageProjectTarget(
        repositoryID: "github.com/one/shared", repositoryName: "shared",
        repositoryURL: "https://github.com/one/shared.git/")
    static let beta = UsageProjectTarget(
        repositoryID: "github.com/two/shared", repositoryName: "shared",
        repositoryURL: "https://github.com/two/shared")
    static let unique = UsageProjectTarget(
        repositoryID: "github.com/acme/edith", repositoryName: "edith",
        repositoryURL: "https://github.com/acme/edith")

    @Test func descriptorsAreUniqueCompleteAndClassified() {
        let descriptors = UsageProjectOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.cli.starts(with: ["usage", "projects"]) })
        #expect(UsageProjectOperation.list.descriptor.effect == .read)
        #expect(UsageProjectOperation.show.descriptor.effect == .read)
        #expect(UsageProjectOperation.openRepository.descriptor.effect == .interactive)
        #expect(UsageProjectOperation.copyRepositoryLink.descriptor.effect == .write)
        #expect(UsageProjectOperation.copyChatID.descriptor.effect == .write)
    }

    @Test func resolverAcceptsStableIdentityNameAndNormalizedURL() throws {
        let projects = [Self.unique]
        #expect(
            try UsageProjectOperationExecution.resolve(
                "GITHUB.COM/ACME/EDITH", in: projects) == Self.unique)
        #expect(try UsageProjectOperationExecution.resolve("Edith", in: projects) == Self.unique)
        #expect(
            try UsageProjectOperationExecution.resolve(
                "https://github.com/acme/edith.git/", in: projects) == Self.unique)
    }

    @Test func duplicateVisibleNamesRequireAStableIdentity() throws {
        #expect(throws: UsageProjectOperationError.self) {
            try UsageProjectOperationExecution.resolve("shared", in: [Self.beta, Self.alpha])
        }
        let resolved = try UsageProjectOperationExecution.resolve(
            "github.com/two/shared", in: [Self.beta, Self.alpha])
        #expect(resolved == Self.beta)
    }

    @Test func missingAndEmptyQueriesAreDeterministic() {
        #expect(throws: UsageProjectOperationError.emptyQuery) {
            try UsageProjectOperationExecution.resolve("  ", in: [Self.unique])
        }
        #expect(throws: UsageProjectOperationError.projectNotFound("missing")) {
            try UsageProjectOperationExecution.resolve("missing", in: [Self.unique])
        }
    }

    @Test func repositoryLinksMustBeHTTPAndPresent() {
        let missing = UsageProjectTarget(
            repositoryID: "folder:local", repositoryName: "local", repositoryURL: nil)
        let invalid = UsageProjectTarget(
            repositoryID: "github.com/acme/private", repositoryName: "private",
            repositoryURL: "git@github.com:acme/private.git")
        #expect(throws: UsageProjectOperationError.repositoryLinkUnavailable("local")) {
            try UsageProjectOperationExecution.repositoryURL(for: missing)
        }
        #expect(
            throws: UsageProjectOperationError.invalidRepositoryLink(
                "git@github.com:acme/private.git")
        ) {
            try UsageProjectOperationExecution.repositoryURL(for: invalid)
        }
    }

    @Test func openAndCopyUseTheSameValidatedTarget() throws {
        var opened: URL?
        let openResult = try UsageProjectOperationExecution.openRepository(Self.unique) {
            opened = $0
            return true
        }
        var copied = ""
        let copyResult = try UsageProjectOperationExecution.copyRepositoryLink(Self.unique) {
            copied = $0
            return true
        }
        #expect(opened?.absoluteString == Self.unique.repositoryURL)
        #expect(copied == Self.unique.repositoryURL)
        #expect(openResult.operationID == UsageProjectOperation.openRepository.descriptor.id)
        #expect(copyResult.repositoryID == Self.unique.repositoryID)
    }

    @Test func failedPlatformActionsStayFailures() {
        #expect(throws: UsageProjectOperationError.actionFailed("open edith")) {
            try UsageProjectOperationExecution.openRepository(Self.unique) { _ in false }
        }
        #expect(
            throws: UsageProjectOperationError.actionFailed("copy the link for edith")
        ) {
            try UsageProjectOperationExecution.copyRepositoryLink(Self.unique) { _ in false }
        }
    }

    @Test func chatCopyTrimsAndRejectsEmptyValues() throws {
        var copied = ""
        let result = try UsageProjectOperationExecution.copyChatID("  chat-42  ") {
            copied = $0
            return true
        }
        #expect(copied == "chat-42")
        #expect(result.value == "chat-42")
        #expect(result.operationID == UsageProjectOperation.copyChatID.descriptor.id)
        #expect(throws: UsageProjectOperationError.emptyChatID) {
            try UsageProjectOperationExecution.copyChatID(" ") { _ in true }
        }
    }

}
