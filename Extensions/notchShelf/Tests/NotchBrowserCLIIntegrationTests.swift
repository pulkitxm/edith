import EdithExtensionSupport
import Foundation
import Testing
import WebKit
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchBrowserCLIIntegrationTests {
    @Test func originalCLIChangesActualUnshownNativeBrowserAndReturnsItsResult() async throws {
        let server = try BrowserHTTPFixture(pages: [
            "/": "<title>synthetic first browser page</title>",
            "/two": "<title>synthetic second browser page</title>",
        ])
        defer { server.stop() }
        let origin = try await server.origin()
        let fixture = try NotchBrowserNativePresentationTests.Fixture(tabs: [origin.absoluteString])
        defer { fixture.clean() }
        let queue = fixture.engine.cliQueue
        var admitted = true
        queue.admitted = { _ in admitted }
        var attached = false
        var completed = 0
        let client = NotchBrowserCommandClient(
            request: { fixture.request($0) },
            invoke: {
                let result = try await fixture.engine.execute($0)
                if $0.operation == .commandAttach { attached = true }
                if $0.operation == .commandResult { completed += 1 }
                return result
            }, perform: { try fixture.store.perform($0) })
        fixture.engine.changed = { client.refresh() }
        client.refresh()
        try await eventually { attached }
        var copied: [String] = []
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await BrowserCLIExecution.run(
                .init(arguments: arguments),
                request: {
                    try await queue.invoke($0)
                }, copy: { copied.append($0) })
        }
        #expect(try await run(["ls", "--json"]).stdout.contains("Mock original browser"))
        #expect(try await run(["profile", "Default", "--json"]).exitCode == 0)
        try await eventually { fixture.store.selectedTab?.title == "synthetic first browser page" }
        let tab = try #require(fixture.store.selectedTab)
        #expect(tab.webView.window == nil)
        #expect(
            try await run(["navigate", origin.appendingPathComponent("two").absoluteString])
                .exitCode == 0)
        try await eventually { tab.title == "synthetic second browser page" }
        #expect(try await run(["reload", "--hard"]).exitCode == 0)
        try await eventually { !tab.isLoading && tab.title == "synthetic second browser page" }
        #expect(try await run(["copy"]).exitCode == 0)
        #expect(copied == [origin.appendingPathComponent("two").absoluteString])
        #expect(try await run(["duplicate"]).exitCode == 0)
        #expect(fixture.store.tabs.count == 2)
        #expect(try await run(["tab", "about:blank"]).exitCode == 0)
        #expect(fixture.store.tabs.count == 3)
        #expect(try await run(["close-right", "--tab", "1", "--yes"]).exitCode == 0)
        #expect(fixture.store.tabs.count == 1)
        #expect(try await run(["reopen"]).exitCode == 0)
        #expect(fixture.store.tabs.count == 2)
        #expect(try await run(["close-others", "--tab", "1", "--yes"]).exitCode == 0)
        #expect(fixture.store.tabs.count == 1)
        #expect(try await run(["close", "--yes"]).exitCode == 0)
        #expect(fixture.store.tabs.count == 1)
        #expect(try await run(["sync", "--json"]).exitCode == 0)
        try await eventually { fixture.store.permitsNativeNavigation }
        let rejected = try await run(["navigate", "file:///synthetic-private.txt"])
        #expect(rejected.exitCode != 0)
        #expect(fixture.store.tabs.allSatisfy { $0.webView.window == nil })
        #expect(try await run(["detach", "--yes"]).exitCode == 0)
        #expect(fixture.store.tabs.isEmpty && fixture.store.profile == nil)
        #expect(completed >= 18)
        admitted = false
        await client.stopAndWait()
        await #expect(throws: (any Error).self) { try await queue.invoke(.status) }
        #expect(queue.pendingCount == 0)
        await fixture.store.shutdownAndWait()
    }

    @Test func cancelledDeliveredCommandCannotMutateNativeBrowser() async throws {
        let fixture = try NotchBrowserNativePresentationTests.Fixture(tabs: [])
        defer { fixture.clean() }
        let initial = fixture.store.snapshot()
        let queue = fixture.engine.cliQueue
        queue.admitted = { _ in true }
        var attached = false
        var beforeValidation: CheckedContinuation<Void, Never>?
        var effects = 0
        let client = NotchBrowserCommandClient(
            request: { fixture.request($0) },
            invoke: {
                if $0.operation == .commandValidate {
                    await withCheckedContinuation { beforeValidation = $0 }
                }
                let data = try await fixture.engine.execute($0)
                if $0.operation == .commandAttach { attached = true }
                return data
            },
            perform: { request in
                effects += 1; return try fixture.store.perform(request)
            })
        fixture.engine.changed = { client.refresh() }
        client.refresh()
        try await eventually { attached }
        let command = Task { try await queue.invoke(.profile("Default")) }
        try await eventually { beforeValidation != nil }
        command.cancel()
        await #expect(throws: CancellationError.self) { try await command.value }
        beforeValidation?.resume(); beforeValidation = nil
        await client.stopAndWait()
        #expect(effects == 0 && queue.pendingCount == 0)
        #expect(fixture.store.snapshot() == initial)
        await fixture.store.shutdownAndWait()
    }

    @Test func chromeClientAdmissionRequiresCurrentExpandedBrowserAndPresenterPermission()
        async throws
    {
        let browser = try NotchBrowserNativePresentationTests.Fixture(tabs: [])
        defer { browser.clean() }
        let panel = try NotchPanelFixture()
        defer { panel.clean() }
        panel.defaults.set(true, forKey: AppStorageKeys.Notch.browserEnabled)
        _ = try panel.attach()
        let controller = panel.bind(createBrowserEngine: { _ in browser.engine })
        controller.synchronize()
        controller.expand(on: 42, preferredTab: .browser)
        var commandAttaches = 0
        let chrome = NotchChromeClient(
            displayID: 42, presentationID: panel.presentation, namespace: panel.id
        ) {
            operation, payload in
            switch operation {
            case "notch.chrome.read":
                return try JSONEncoder().encode(
                    panel.engine.chrome(JSONDecoder().decode(NotchChromeRead.self, from: payload)))
            case "notch.chrome.browser":
                let request = try JSONDecoder().decode(
                    NotchBrowserRemoteRequest.self, from: payload)
                let response = try await panel.engine.browser(request)
                if request.operation == .commandAttach { commandAttaches += 1 }
                return response
            default: throw ExtensionPeerError.invalidRequest
            }
        }
        await chrome.refresh()
        try await eventually { commandAttaches > 0 }
        let command = Task { try await browser.engine.cliQueue.invoke(.status) }
        try await eventually { browser.engine.cliQueue.pendingCount == 1 }
        await chrome.refresh()
        let result = try await command.value
        #expect(result.profiles.first?.name == "Mock original browser")
        #expect(chrome.browser?.tabs.isEmpty == true)
        controller.collapseNow()
        await chrome.refresh()
        await #expect(throws: (any Error).self) {
            try await browser.engine.cliQueue.invoke(.status)
        }
        controller.expand(on: 42, preferredTab: .browser)
        let before = commandAttaches
        await chrome.refresh()
        try await eventually { commandAttaches > before }
        let queued = Task { try await browser.engine.cliQueue.invoke(.status) }
        try await eventually { browser.engine.cliQueue.pendingCount == 1 }
        let presenter = ExtensionSharedState(
            root: panel.root, namespace: panel.id, owner: "presenter")
        try presenter.publish(["active": "1", "blurBrowser": "1"])
        controller.privacy.refresh()
        await chrome.refresh()
        await #expect(throws: (any Error).self) { try await queued.value }
        #expect(browser.engine.cliQueue.pendingCount == 0)
        await chrome.stopAndWait()
        NotchPresenterState.shared.remoteValues = nil
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderReadCorrupt) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
