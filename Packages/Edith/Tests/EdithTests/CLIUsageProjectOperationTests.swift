import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIUsageProjectOperationTests {
    @Test func registeredDescriptorsReachParserAndCompletionLeaves() throws {
        let descriptors = UsageProjectOperation.allCases.map(\.descriptor)
        #expect(descriptors.allSatisfy(UserOperationCatalog.descriptors.contains))
        let arguments = [
            ["usage", "projects", "list"],
            ["usage", "projects", "show", "edith"],
            ["usage", "projects", "open", "edith"],
            ["usage", "projects", "copy-link", "edith"],
            ["usage", "projects", "copy-chat", "chat-42"],
        ]
        for value in arguments {
            _ = try EdRoot.parseAsRoot(value)
        }
        for descriptor in descriptors {
            var node = CommandTree.root
            for segment in descriptor.cli {
                node = try #require(node.child(segment))
            }
            #expect(node.children.isEmpty)
        }
    }

    @Test func actionJSONHasStableFields() {
        let result = UsageProjectOperationResult(
            operationID: UsageProjectOperation.copyRepositoryLink.descriptor.id,
            repositoryID: "github.com/acme/edith", value: "https://github.com/acme/edith")
        guard case let .object(fields) = result.json else {
            Issue.record("operation result should be an object")
            return
        }
        #expect(
            Set(fields.keys) == ["operation", "repositoryID", "value", "performed"])
        #expect(fields["operation"] == .string("usage.projects.copyRepositoryLink"))
        #expect(fields["repositoryID"] == .string("github.com/acme/edith"))
        #expect(fields["performed"] == .bool(true))
    }

    @Test func operationErrorsKeepStableExitClasses() {
        #expect(UsageProjectOperationError.emptyChatID.cliFailure.kind == .usage)
        #expect(
            UsageProjectOperationError.projectNotFound("missing").cliFailure.kind == .notFound)
        #expect(
            UsageProjectOperationError.projectAmbiguous("shared", ["one", "two"])
                .cliFailure.kind == .notFound)
        #expect(
            UsageProjectOperationError.repositoryLinkUnavailable("local").cliFailure.kind
                == .unavailable)
        #expect(
            UsageProjectOperationError.actionFailed("copy the chat identifier").cliFailure.kind
                == .unavailable)
    }

    @Test func defaultGroupStillSelectsTheListCommand() throws {
        let root = try EdRoot.parseAsRoot(["usage", "projects", "--limit", "25"])
        let list = try #require(root as? UsageProjectsListCommand)
        #expect(list.limit == 25)
    }

    @Test func plainHierarchyRowsExposeEveryChatIdentifier() {
        let direct = UsageProjectChatSummary(
            id: "main-chat", title: "Main", path: "/tmp/edith", source: "cli",
            cost: 1, tokens: 10, lastTs: nil)
        let nested = UsageProjectChatSummary(
            id: "work-chat", title: "Work", path: "/tmp/edith-worktree", source: "codex",
            cost: 2, tokens: 20, lastTs: nil)
        let folder = UsageProjectFolderSummary(
            folderName: "edith", path: "/tmp/edith", machineName: "Laptop",
            machineID: "laptop", cost: 3, tokens: 30, chats: [direct],
            worktrees: [
                UsageProjectWorktreeSummary(
                    name: "feature", cost: 2, tokens: 20, chats: [nested])
            ])
        let summary = UsageProjectSummary(
            repositoryID: "github.com/acme/edith", repositoryName: "edith",
            repositoryURL: "https://github.com/acme/edith", cost: 3, tokens: 30,
            folders: [folder])
        let rows = UsageProjectsShowCommand.hierarchyRows(summary)

        #expect(rows.map(\.first) == ["folder", "chat", "worktree", "chat"])
        #expect(rows.map { $0[2] } == ["-", "main-chat", "-", "work-chat"])
        #expect(rows[3][1] == "    Work")
    }
}
