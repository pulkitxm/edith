import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct BrowserCLITests {
    private func snapshot() -> NotchBrowserSnapshot {
        .init(
            attached: true, profile: .init(id: "Default", name: "Synthetic"),
            profiles: [.init(id: "Default", name: "Synthetic")],
            tabs: [
                .init(
                    id: UUID().uuidString, index: 1, title: "Mock page",
                    url: "http://127.0.0.1/one", selected: true, loading: false)
            ], sync: "idle", canReopen: true, link: "http://127.0.0.1/one")
    }

    @Test func originalCommandsPreserveFixedRequestsAndDestructivePreview() async throws {
        let state = snapshot()
        var requests: [NotchBrowserRequest] = []
        var copied: [String] = []
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await BrowserCLIExecution.run(
                .init(arguments: arguments),
                request: {
                    requests.append($0); return state
                }, copy: { copied.append($0) })
        }
        #expect(try await run(["list", "--json"]).exitCode == 0)
        #expect(requests.last == .status)
        #expect(try await run(["navigate", "http://127.0.0.1/two", "--tab", "1"]).exitCode == 0)
        #expect(requests.last == .navigate("http://127.0.0.1/two", tab: "1"))
        #expect(try await run(["reload", "--hard"]).exitCode == 0)
        #expect(requests.last == .reload(hard: true, tab: nil))
        #expect(try await run(["copy", "--json"]).exitCode == 0)
        #expect(copied == [state.link!])
        for (command, expected) in [
            ("close", NotchBrowserRequest.close(tab: state.tabs[0].id)),
            ("close-others", .closeOthers(tab: state.tabs[0].id)),
            ("close-right", .closeRight(tab: state.tabs[0].id)),
        ] {
            let before = requests.count
            let preview = try await run([command, "--tab", "1", "--json"])
            #expect(preview.exitCode == 0 && preview.stdout.contains("\"applied\": false"))
            #expect(requests.count == before + 1 && requests.last == .status)
            #expect(try await run([command, "--tab", "1", "--yes"]).exitCode == 0)
            #expect(requests.last == expected)
        }
        #expect(try await run(["detach", "--json"]).stdout.contains("\"applied\": false"))
        #expect(requests.last == .status)
        #expect(try await run(["detach", "--yes"]).exitCode == 0 && requests.last == .detach)
        for (arguments, expected) in [
            (["reopen"], NotchBrowserRequest.reopen), (["duplicate"], .duplicate(tab: nil)),
            (["sync"], .sync), (["profile", "Synthetic"], .profile("Synthetic")),
            (["tab", "about:blank"], .newTab("about:blank")),
        ] {
            #expect(try await run(arguments).exitCode == 0)
            #expect(requests.last == expected)
        }
    }

    @Test func fullRequestContextHelpFailureAndCombinedCatalogArePreserved() async throws {
        let state = snapshot()
        let input = try ExtensionCLIRequest(
            arguments: ["ls", "--json"],
            standardInput: Data("synthetic stdin".utf8), workingDirectory: "/synthetic/browser",
            interactive: true)
        let reply = try await BrowserCLIExecution.run(
            input,
            request: { _ in
                #expect(ExtensionCLIContext.request == input)
                return state
            }, copy: { _ in Issue.record("Listing cannot copy") })
        #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
        #expect(reply.stdout.contains("Mock page"))
        let help = try await BrowserCLIExecution.run(
            .init(arguments: ["--help"]),
            request: { _ in
                Issue.record("Help cannot contact a browser"); return state
            })
        #expect(help.exitCode == 0 && help.stdout.contains("close-others"))
        let failed = try await BrowserCLIExecution.run(
            .init(arguments: ["ls"]),
            request: { _ in
                throw NotchBrowserActionError("No current browser presentation.")
            })
        #expect(failed.exitCode != 0 && failed.stdout.isEmpty)
        #expect(failed.stderr.contains("No current browser presentation."))
        let data = try NotchCLIProviderCatalog.encode(Data("{}".utf8))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["owner"] as? String == "notchShelf")
        let commands = try #require(catalog["commands"] as? [[String: Any]])
        #expect(
            Set(commands.compactMap { ($0["route"] as? [String])?.first }) == ["shelf", "browser"])
        #expect((catalog["parserHelp"] as? [[String: Any]])?.count == 2)
        #expect(
            commands.filter { ($0["route"] as? [String])?.first == "browser" }.allSatisfy {
                $0["operation"] as? String == "browser.cli"
                    && $0["streamOperation"] as? String == "browser.cli"
            })
        #expect(throws: (any Error).self) { try NotchCLIProviderCatalog.encode(Data("[]".utf8)) }
    }

    @Test func cancellationAfterNativeReplyDoesNotCopyOrEmitSuccess() async throws {
        let state = snapshot()
        var copied = false
        let task = Task {
            try await BrowserCLIExecution.run(
                .init(arguments: ["copy", "--json"]),
                request: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return state
                }, copy: { _ in copied = true })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!copied)
    }

    @Test func runtimePublishesBothCatalogsAndHelpWithoutStartingBrowserOrPanel() async throws {
        var ownersCreated = 0
        let runtime = ExtensionRuntime(
            contextSource: { nil }, connectedDisplays: { [:] },
            createController: { _, _ in
                ownersCreated += 1; fatalError("No owner is allowed")
            })
        func invoke<T: Encodable>(_ operation: String, _ input: T) async throws -> Data {
            let payload = try JSONEncoder().encode(input)
            return try await withCheckedThrowingContinuation { continuation in
                runtime.invoke([
                    "token": UUID().uuidString, "command": operation, "payload": payload,
                ]) {
                    data, error in
                    if let data {
                        continuation.resume(returning: data as Data)
                    } else {
                        continuation.resume(
                            throwing: ExtensionPeerError.rejected(error as String? ?? "No reply"))
                    }
                }
            }
        }
        let data = try await invoke("notchShelf.cli.catalog", [String: String]())
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((catalog["parserHelp"] as? [[String: Any]])?.count == 2)
        let help = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await invoke("browser.cli", ExtensionCLIRequest(arguments: ["--help"])))
        #expect(help.exitCode == 0 && help.stdout.contains("close-others"))
        let unavailable = try JSONDecoder().decode(
            ExtensionCLIReply.self,
            from: await invoke("browser.cli", ExtensionCLIRequest(arguments: ["ls"])))
        #expect(unavailable.exitCode != 0 && unavailable.stdout.isEmpty)
        #expect(ownersCreated == 0)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }

    @Test func streamedCancellationDrainsTheOwnedBrowserQueue() async throws {
        let queue = NotchBrowserCLIQueue()
        queue.admitted = { _ in true }
        let attach = NotchBrowserRemoteRequest(
            identity: .init(ownershipID: UUID(), generation: UUID()),
            displayID: 1, presentationID: UUID(), operation: .commandAttach)
        _ = try queue.attach(attach)
        let streams = try ExtensionCLIStreams(owner: "notchShelf")
        let handle = try BrowserCLIEnvironment.$configuration.withValue(
            BrowserCLIExecution.configuration(
                request: { try await queue.invoke($0) }, copy: { _ in })
        ) {
            try streams.start(
                BrowserCommand.self,
                request: .init(
                    owner: "notchShelf", session: UUID(), request: .init(arguments: ["ls"]),
                    deadline: 30)
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while queue.pendingCount == 0 {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        try streams.cancel(handle)
        await streams.stopAndWait()
        #expect(queue.pendingCount == 0)
        queue.stop()
    }
}
