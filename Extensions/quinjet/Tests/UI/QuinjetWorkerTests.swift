import EdithExtensionSupport
import Foundation
import Testing
@testable import QuinjetUI

@MainActor @Suite(.serialized) struct QuinjetWorkerTests {
    @Test func savedMachineSelectionsRetainTheirRemoteIdentityAndRejectOtherMachines() async throws
    {
        let id = UUID()
        let remote = QuinjetRemote(
            machineID: id, machineName: "Synthetic remote", target: "mock@synthetic.invalid",
            controlPath: "/tmp/mock-master",
            sshArguments: SSHConnection.masterOnlyOptions + [
                "-p", "2222", "-S", "/tmp/mock-master", "--", "mock@synthetic.invalid",
            ], executablePath: "/tmp/mock-quinjet")
        let client = QuinjetClient(
            execute: { arguments in
                #expect(arguments == ["remote", "list", "--json"])
                return Data(
                    #"{"remotes":[{"target":"mock@synthetic.invalid","folder":"/tmp/synthetic-project","accessible":true,"uses":1}]}"#
                        .utf8)
            },
            executeRemote: { selected, arguments in
                #expect(selected == remote)
                #expect(
                    arguments == ["-C", "/tmp/synthetic-project", "worktree", "list", "--json"])
                return try JSONEncoder().encode([
                    QuinjetWorktree(
                        path: "/tmp/synthetic-project", head: "1234567", branch: "main",
                        current: true, bare: false, detached: false, locked: nil, prunable: nil)
                ])
            })
        let worker = QuinjetWorker(
            client: client,
            resolveRemote: { selected in
                guard selected == id else { throw ExtensionPeerError.invalidRequest }
                return remote
            }, automaticActions: false)
        await worker.start()
        let projects = try object(
            await worker.execute(
                "quinjet.projects",
                payload: JSONSerialization.data(withJSONObject: ["machineID": id.uuidString])))
        let project = try #require((projects["projects"] as? [[String: String]])?.first)
        #expect(project["machineID"] == id.uuidString)
        let trees = try object(
            await worker.execute(
                "quinjet.worktrees",
                payload: JSONSerialization.data(withJSONObject: ["projectID": project["id"]!])))
        let tree = try #require((trees["worktrees"] as? [[String: String]])?.first?["id"])
        _ = try await worker.execute(
            "quinjet.select", payload: JSONSerialization.data(withJSONObject: ["worktreeID": tree]))
        #expect(worker.model.selectedTab?.remote == remote)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.projects",
                payload: JSONSerialization.data(withJSONObject: ["machineID": UUID().uuidString]))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.projects", payload: Data(#"{"sshTarget":"injected.invalid"}"#.utf8))
        }
        await worker.shutdown()
    }

    @Test func cancellationStopsCollectionWithoutAdmittingAnyCurrentProjects() async throws {
        var started = false
        var stopped = false
        let worker = QuinjetWorker(
            client: QuinjetClient { _ in
                await MainActor.run { started = true }
                defer { Task { @MainActor in stopped = true } }
                try await Task.sleep(for: .seconds(60))
                return Data("[]".utf8)
            }, automaticActions: false)
        await worker.start()
        let task = Task { try await worker.execute("quinjet.projects", payload: Data("{}".utf8)) }
        while !started { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        while !stopped { await Task.yield() }
        #expect(worker.model.projects.isEmpty)
        await worker.shutdown()
    }

    @Test func boundedCurrentSelectionsDriveFullReviewAndRejectInjectedPaths() async throws {
        let worker = QuinjetWorker(
            client: client, previewExecutable: { URL(fileURLWithPath: "/tmp/synthetic-quinjet") },
            automaticActions: false)
        await worker.start()
        let projects = try object(
            await worker.execute("quinjet.projects", payload: Data("{}".utf8)))
        let project = try #require((projects["projects"] as? [[String: String]])?.first?["id"])
        let trees = try object(
            await worker.execute(
                "quinjet.worktrees",
                payload: JSONSerialization.data(withJSONObject: ["projectID": project])))
        let tree = try #require((trees["worktrees"] as? [[String: String]])?.first?["id"])
        let before = worker.model.selectedTab?.worktree
        let preview = try object(
            await worker.execute(
                "quinjet.open",
                payload: JSONSerialization.data(withJSONObject: ["worktreeID": tree])))
        #expect(preview["executable"] as? String == "/tmp/synthetic-quinjet")
        #expect((preview["arguments"] as? [String])?.contains("tui") == true)
        #expect(worker.model.selectedTab?.worktree == before)
        _ = try await worker.execute(
            "quinjet.select", payload: JSONSerialization.data(withJSONObject: ["worktreeID": tree]))
        #expect(worker.model.selectedTab?.projectName == "Synthetic")
        #expect(worker.model.selectedTab?.worktree?.branch == "main")
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.select", payload: Data(#"{"path":"/private/injected"}"#.utf8))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.worktrees",
                payload: JSONSerialization.data(withJSONObject: ["projectID": UUID().uuidString]))
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "quinjet.session.focus", payload: Data(#"{"sessionID":"1"}"#.utf8))
        }
        await worker.shutdown()
        #expect(worker.isStopped && QuinjetWorkOwnership.pendingCount == 0)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("quinjet.projects", payload: Data("{}".utf8))
        }
    }
    @Test func surfacesShowGitHubPullRequestsFilterByRepositoryAndKind() async throws {
        let worker = QuinjetWorker(client: client, automaticActions: false)
        await worker.start()
        let response = Self.pullResponse
        let github = QuinjetGitHubClient { arguments in
            arguments.contains("user") ? Data("octo\n".utf8) : response
        }
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.github))
        let surface = QuinjetSurface(worker: worker, github: github, privacyValues: { [:] })
        let snapshot = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "quinjet")),
            providerID: "quinjet")
        #expect(snapshot.metrics.map(\.value) == ["2", "1", "1", "1"])
        #expect(snapshot.rows.map(\.id) == ["PR_review", "PR_authored"])
        #expect(snapshot.rows.first?.value == "Review requested")
        #expect(snapshot.sources.map(\.id) == ["acme/api", "acme/web"])
        var tile = SurfaceTile(.github)
        tile.sourceIDs = ["acme/web"]
        let filtered = try await surface.snapshot(tile)
        #expect(filtered.rows.map(\.id) == ["PR_authored"])
        tile.sourceIDs = nil
        tile.contentKinds = ["review"]
        let reviews = try await surface.snapshot(tile)
        #expect(reviews.rows.map(\.id) == ["PR_review"])
        let action = try #require(snapshot.rows.first?.actions.first?.id)
        #expect(action == "open/PR_review")
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "open/unknown").encoded(
                    providerID: "quinjet"))
        }
        let hidden = QuinjetSurface(
            worker: worker, github: github, privacyValues: { ["active": "1"] })
        let covered = try SurfaceSnapshot.decode(
            await hidden.execute(
                "surface.snapshot", payload: request.encoded(providerID: "quinjet")),
            providerID: "quinjet")
        #expect(covered.rows.isEmpty && covered.message == "Hidden while presenting.")
        await worker.shutdown()
    }
    @Test func gitHubFailuresSurfaceReadableErrors() async throws {
        let worker = QuinjetWorker(client: client, automaticActions: false)
        await worker.start()
        let surface = QuinjetSurface(
            worker: worker,
            github: QuinjetGitHubClient { _ in throw QuinjetGitHubError.authentication },
            privacyValues: { [:] })
        await #expect(throws: QuinjetGitHubError.self) {
            try await surface.snapshot(.init(.github))
        }
        let malformed = QuinjetSurface(
            worker: worker, github: QuinjetGitHubClient { _ in Data("not json".utf8) },
            privacyValues: { [:] })
        await #expect(throws: QuinjetGitHubError.self) {
            try await malformed.snapshot(.init(.github))
        }
        await worker.shutdown()
    }
    private static let pullResponse = Data(
        """
        {"data":{
          "authored":{"pageInfo":{"hasNextPage":false},"nodes":[
            {"id":"PR_authored","url":"https://github.com/acme/web/pull/7","title":"Add tile",
             "number":7,"isDraft":false,"updatedAt":"2026-01-02T00:00:00Z",
             "reviewDecision":"APPROVED","repository":{"nameWithOwner":"acme/web"},
             "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}]},
          "review":{"pageInfo":{"hasNextPage":false},"nodes":[
            {"id":"PR_review","url":"https://github.com/acme/api/pull/9","title":"Fix auth",
             "number":9,"isDraft":false,"updatedAt":"2026-01-01T00:00:00Z",
             "reviewDecision":null,"repository":{"nameWithOwner":"acme/api"},
             "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}]},
          "assigned":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}
        """.utf8)
    @Test func oversizedNativeMetadataIsRejectedBeforeCurrentSelectionsAreAdmitted() async throws {
        let client = QuinjetClient { _ in
            try JSONEncoder().encode([
                QuinjetProject(
                    name: "Synthetic", commonDir: "/tmp/synthetic/.git",
                    worktrees: [
                        QuinjetWorktree(
                            path: "/tmp/synthetic", head: "1234567",
                            branch: String(repeating: "b", count: 1025), current: true, bare: false,
                            detached: false, locked: nil, prunable: nil)
                    ])
            ])
        }
        let worker = QuinjetWorker(client: client, automaticActions: false)
        await worker.start()
        await #expect(throws: QuinjetClientError.invalidResponse) {
            try await worker.execute("quinjet.projects", payload: Data("{}".utf8))
        }
        #expect(worker.model.projects.isEmpty)
        await worker.shutdown()
    }

    private var client: QuinjetClient {
        QuinjetClient { arguments in
            if arguments.contains("-C") {
                return try JSONEncoder().encode([
                    QuinjetWorktree(
                        path: "/tmp/synthetic-project", head: "1234567", branch: "main",
                        current: true, bare: false, detached: false, locked: nil, prunable: nil)
                ])
            }
            return try JSONEncoder().encode([
                QuinjetProject(
                    name: "Synthetic", commonDir: "/tmp/synthetic-project/.git",
                    worktrees: [
                        QuinjetWorktree(
                            path: "/tmp/synthetic-project", head: "1234567", branch: "main",
                            current: true, bare: false, detached: false, locked: nil, prunable: nil)
                    ])
            ])
        }
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
