import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIUsageProjectOperationTests {
    @Test func registeredDescriptorsReachParserAndCompletionLeaves() throws {
        let descriptors = UsageProjectOperation.allCases.map(\.descriptor)
        #expect(UserOperationCatalog.descriptors.suffix(descriptors.count) == descriptors[...])
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

    @Test func defaultGroupStillSelectsTheListCommand() throws {
        let root = try EdRoot.parseAsRoot(["usage", "projects", "--limit", "25"])
        let list = try #require(root as? UsageProjectsListCommand)
        #expect(list.limit == 25)
    }
}
