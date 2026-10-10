import AppKit
import EdithDocsWorker
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import DocsExtension

@Suite(.serialized) @MainActor
struct DocsBrowserTests {
    static let library = DocsLibrary(sources: [
        .init(path: "README.md", markdown: "# Reference\n\nSynthetic command reference."),
        .init(path: "herdr/README.md", markdown: "# `ed herdr`\n\nManage sessions."),
        .init(
            path: "herdr/ls.md",
            markdown: "# `ed herdr ls`\n\nLists sessions.\n\n## Options\n\n`--json`"),
    ])

    @Test func browserLoadsFiltersNavigatesAndSearches() async throws {
        let browser = DocsBrowser(library: Self.library, filterDelay: .zero)
        await browser.load()
        browser.noteFilter("ls")
        await browser.settleFilter()
        #expect(browser.sidebarGroups.flatMap { $0.1 }.map(\.path) == ["herdr/ls.md"])
        browser.open(.init(path: "herdr/ls.md", anchor: "options"))
        #expect(browser.scroll.anchor == "options")
        browser.question = "list sessions"
        await browser.submit(decider: nil)
        #expect(browser.answer?.picks.first?.command.route == "herdr ls")
        #expect(browser.answer?.engine == .search)
        browser.openSelection()
        #expect(browser.location.path == "herdr/ls.md")
        browser.open(.init(path: "missing.md"))
        #expect(browser.location.path == "herdr/ls.md")
        browser.shutdown()
        await browser.load()
        #expect(browser.library == nil)
        #expect(browser.sidebarGroups.isEmpty)
    }

    @Test func shutdownPreventsLateFilterPublication() async throws {
        let browser = DocsBrowser(library: Self.library, filterDelay: .milliseconds(10))
        browser.noteFilter("sessions")
        browser.shutdown()
        await browser.settleFilter()
        try await Task.sleep(for: .milliseconds(30))
        #expect(browser.sidebarGroups.isEmpty)
        #expect(browser.library == nil)
        #expect(!browser.asking)
    }

    @Test func shutdownCancelsAnOwnedPeerCallAndRejectsLateAnswers() async throws {
        let suite = "docs-fixture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        JevAvailability.record(configured: true, in: defaults)
        let browser = DocsBrowser(library: Self.library, defaults: defaults)
        let peer = SlowDocsPeer()
        let task = Task { await browser.ask("list sessions", decider: peer) }
        await peer.waitUntilStarted()
        browser.shutdown()
        await task.value
        #expect(await peer.cancelled)
        #expect(browser.answer == nil)
        #expect(!browser.asking && !browser.resultsVisible)
    }

    @Test func surfaceEncodesBoundedBundledPagesAndGroupSources() throws {
        let library = try #require(DocsLibrary.bundled())
        let snapshot = DocsSurface.snapshot(library: library, location: .init(path: "README.md"))
        let encoded = try snapshot.encoded()
        #expect(encoded.count <= 524_288)
        #expect(snapshot.rows.count == min(100, library.pages.count))
        #expect(snapshot.rows.allSatisfy { !$0.actions.isEmpty })
        #expect(snapshot.sources.first?.id == "overview")
        var tile = SurfaceTile(.ability("docs"))
        tile.itemLimit = 1
        tile.showActions = false
        let hidden = SurfaceCommandService.project(snapshot, tile: tile)
        #expect(hidden.rows.count == 1)
        #expect(hidden.rows.allSatisfy { $0.actions.isEmpty })
    }

    @Test func surfaceTruncatesAnOversizedLibraryToOneHundredRows() throws {
        let library = DocsLibrary(
            sources: (0..<120).map {
                .init(
                    path: "reference/page-\($0).md",
                    markdown: "# Page \($0)\n\nSynthetic reference.")
            })
        let snapshot = DocsSurface.snapshot(library: library, location: .init(path: "README.md"))
        #expect(library.pages.count == 120)
        #expect(snapshot.rows.count == 100)
        #expect(Set(snapshot.rows.map(\.id)).count == 100)
        #expect(try snapshot.encoded().count <= 524_288)
    }

    @Test func terminalStreamsRetainTheOwnedLibraryAndRejectForeignOwners() async throws {
        let browser = DocsBrowser(library: Self.library)
        let streams = try ExtensionCLIStreams(owner: "docs")
        let start = ExtensionCLIStreamStart(
            owner: "docs", session: UUID(),
            request: try .init(
                arguments: ["ls", "--json"], workingDirectory: "/tmp", interactive: false))
        let payload = try await DocsCLIExecution.stream(
            streams, operation: "docs.cli.start",
            payload: JSONEncoder().encode(start), browser: browser)
        let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: payload)
        var sequence: UInt64 = 0
        var output = Data()
        for _ in 0..<200 {
            let frame = try streams.read(.init(handle: handle, sequence: sequence))
            for chunk in frame.chunks {
                #expect(chunk.channel == .stdout); output.append(chunk.data)
            }
            sequence = frame.nextSequence
            if frame.state != .running {
                #expect(frame.state == .completed && frame.exitCode == 0); break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(String(decoding: output, as: UTF8.self).contains("herdr/ls.md"))
        #expect(DocsCLIEnvironment.library == nil)
        let foreign = ExtensionCLIStreamStart(
            owner: "other", session: UUID(), request: start.request)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await DocsCLIExecution.stream(
                streams, operation: "docs.cli.start",
                payload: JSONEncoder().encode(foreign), browser: browser)
        }
        await streams.stopAndWait(); await browser.drain()
    }

    @Test func documentViewRetainsCompleteBrowserAndOutlineUI() throws {
        _ = NSApplication.shared
        let browser = DocsBrowser(library: Self.library)
        browser.open(.init(path: "herdr/ls.md"))
        let controller = NSHostingController(
            rootView:
                ExtensionPageHost { DocsScreen(browser: browser) }.frame(width: 1200, height: 800)
                .environment(\.automaticViewActionsEnabled, false))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.fittingSize.width > 0)
        #expect(
            DocsNavigation.title(
                of: try #require(Self.library.page("herdr/ls.md")),
                in: try #require(Self.library.groups.first { $0.id == "herdr" })) == "ls")
        browser.shutdown()
    }

    @Test func invalidPeerPurposeAndOversizedResponseAreRejected() async {
        let request = JevRequest(state: .text("fixture"), questions: ["choice": .noul("choose")])
        let decider = DocsPeerDecider { _ in Data(repeating: 0, count: 524_289) }
        for purpose in ["unowned", DocsAsk.purpose] {
            let error = await #expect(throws: ExtensionPeerError.self) {
                _ = try await decider.decide(request, purpose: purpose)
            }
            guard case .invalidRequest? = error else {
                Issue.record("The peer accepted an invalid purpose or oversized response.")
                continue
            }
        }
    }
}

private actor SlowDocsPeer: JevDeciding {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelled = false

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
        throw ExtensionPeerError.invalidRequest
    }
}

@Suite(.serialized) @MainActor
struct DocsRemoteTests {
    @Test func originalNavigationUsesOwnedEngineSourcesAndAsk() async throws {
        let engine = DocsBrowser(library: DocsBrowserTests.library)
        let remote = DocsBrowser(
            remote: DocsUIBridge(invoke: { command, payload in
                try await DocsUIBridge.execute(command, payload: payload, browser: engine)
            }))
        await remote.load()
        remote.open(.init(path: "herdr/ls.md", anchor: "options"))
        remote.noteFilter("ls")
        await remote.settleFilter()
        #expect(remote.sidebarGroups.flatMap { $0.1 }.map(\.path) == ["herdr/ls.md"])
        remote.question = "list sessions"
        await remote.submit()
        #expect(remote.answer?.picks.first?.command.route == "herdr ls")
        remote.openSelection()
        #expect(remote.location.path == "herdr/ls.md")
        remote.shutdown()
        #expect(engine.library != nil)
        #expect(remote.library == nil)
    }

    @Test func shutdownRejectsLateEngineLibrary() async throws {
        let remote = DocsBrowser(
            remote: DocsUIBridge(invoke: { _, _ in
                try? await Task.sleep(for: .milliseconds(20))
                return try JSONEncoder().encode(
                    DocsBrowserTests.library.pages.map {
                        DocsSource(path: $0.path, markdown: $0.markdown)
                    })
            }))
        let loading = Task { await remote.load() }
        await Task.yield()
        remote.shutdown()
        await loading.value
        #expect(remote.library == nil)
        #expect(remote.sidebarGroups.isEmpty)
    }

    @Test func originalCLIReturnsMarkdownErrorsAndSearch() async throws {
        let engine = DocsBrowser(library: DocsBrowserTests.library)
        let shown = try await DocsCLIExecution.run(
            .init(arguments: ["show", "herdr", "ls"]), browser: engine)
        #expect(shown.stdout == DocsBrowserTests.library.page("herdr/ls.md")!.markdown)
        #expect(shown.stderr.isEmpty && shown.exitCode == 0)
        let missing = try await DocsCLIExecution.run(
            .init(arguments: ["show", "missing"]), browser: engine)
        #expect(missing.exitCode == 3)
        #expect(missing.stdout.isEmpty && missing.stderr.contains("no page documents missing"))
        let answer = try await DocsCLIExecution.run(
            .init(arguments: ["ask", "list sessions", "--json"]), browser: engine)
        let value = try #require(
            JSONSerialization.jsonObject(with: Data(answer.stdout.utf8)) as? [String: Any])
        #expect(value["engine"] as? String == "search")
        #expect((value["picks"] as? [[String: Any]])?.first?["command"] as? String == "ed herdr ls")
        let help = try await DocsCLIExecution.run(.init(arguments: ["--help"]), browser: engine)
        #expect(help.exitCode == 0 && help.stdout.contains("show"))
    }
}
