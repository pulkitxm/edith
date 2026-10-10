import AppKit
import SwiftUI
import Testing

@testable import EdithExtensionUI

@Suite struct NavigationRouteTests {
    @Test func roundTripsSegmentsThatContainSlashes() {
        let route = NavigationRoute(segments: ["docs", "herdr/ls.md", "install"])
        let parsed = NavigationRoute(route.description)
        #expect(parsed?.segments == ["docs", "herdr/ls.md", "install"])
        #expect(route.description == "docs/herdr%2Fls.md/install")
    }

    @Test func rejectsEmptyAndBlankRoutes() {
        #expect(NavigationRoute("") == nil)
        #expect(NavigationRoute("   ") == nil)
        #expect(NavigationRoute("docs//page") == nil)
    }
}

@Suite struct NavigationHistoryTests {
    @Test func recordIgnoresDuplicatesAndTruncatesForward() {
        var history = NavigationHistory()
        history.record("home")
        history.record("home")
        history.record("docs")
        history.record("docs/herdr%2Fls.md")
        #expect(history.goBack() == "docs")
        history.record("machines")
        #expect(history.entries == ["home", "docs", "machines"])
        #expect(!history.canGoForward)
    }

    @Test func backAndForwardWalkTheStack() {
        var history = NavigationHistory()
        history.record("home")
        history.record("companion/chat")
        history.record("companion/library")
        #expect(history.goBack() == "companion/chat")
        #expect(history.goBack() == "home")
        #expect(history.goBack() == nil)
        #expect(history.goForward() == "companion/chat")
        #expect(history.canGoForward)
    }

    @Test func coalesceExtensionReplacesTheCurrentEntry() {
        var history = NavigationHistory()
        history.record("machines")
        history.coalesceExtension("machines/abc/docker")
        #expect(history.entries == ["machines/abc/docker"])
        #expect(!history.canGoBack)
    }

    @Test func coalesceExtensionFillsASegmentThatMountedFirst() {
        var history = NavigationHistory()
        history.record("chat")
        history.coalesceExtension("companion/chat")
        #expect(history.entries == ["companion/chat"])
        #expect(!history.canGoBack)
    }

    @Test func replaceCurrentCollapsesAStaleFallback() {
        var history = NavigationHistory()
        history.record("herdr")
        history.record("herdr/missing")
        history.replaceCurrent("herdr")
        #expect(history.entries == ["herdr"])
        #expect(history.current == "herdr")
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }
}

@MainActor
@Suite(.serialized) struct WindowRouterTests {
    @Test func nestedRegistrationFromTheInsideStillCoalesces() {
        let router = WindowRouter()
        router.register(depth: 1, name: "tab", value: "chat", accept: { _ in true }) { _ in }
        router.register(depth: 0, name: "section", value: "companion", accept: { _ in true }) {
            _ in
        }
        #expect(router.location == "companion/chat")
        #expect(router.history.entries == ["companion/chat"])
    }

    @Test func nestedRegistrationComposesTheLocation() {
        let router = WindowRouter()
        router.register(depth: 0, name: "section", value: "machines", accept: { _ in true }) {
            _ in
        }
        router.register(depth: 1, name: "machine", value: "abc", accept: { _ in true }) { _ in }
        router.register(depth: 2, name: "tab", value: "docker", accept: { _ in true }) { _ in }
        #expect(router.location == "machines/abc/docker")
        #expect(router.history.entries == ["machines/abc/docker"])
    }

    @Test func userNavigationTruncatesForward() {
        let router = WindowRouter()
        router.register(depth: 0, name: "section", value: "home", accept: { _ in true }) { _ in }
        router.userChanged(depth: 0, name: "section", value: "docs", accept: { _ in true }) { _ in
        }
        router.userChanged(depth: 0, name: "section", value: "machines", accept: { _ in true }) {
            _ in
        }
        router.goBack()
        #expect(router.location == "docs")
        router.userChanged(depth: 0, name: "section", value: "companion", accept: { _ in true }) {
            _ in
        }
        #expect(router.history.entries == ["home", "docs", "companion"])
        #expect(!router.canGoForward)
    }

    @Test func restoreDoesNotAppendANewEntry() {
        let router = WindowRouter()
        var section = "home"
        router.register(
            depth: 0, name: "section", value: section, accept: { _ in true },
            apply: { section = $0 })
        router.userChanged(
            depth: 0, name: "section", value: "docs", accept: { _ in true },
            apply: { section = $0 })
        router.goBack()
        #expect(section == "home")
        #expect(router.history.entries == ["home", "docs"])
        #expect(router.history.current == "home")
    }

    @Test func staleNestedIDFallsBackToTheParent() {
        let router = WindowRouter()
        var section = "herdr"
        var agent = ""
        router.register(
            depth: 0, name: "section", value: section,
            accept: { $0 == "herdr" || $0.isEmpty }, apply: { section = $0 })
        router.register(
            depth: 1, name: "agent", value: agent,
            accept: { $0.isEmpty || $0 == "live" },
            apply: { agent = $0 })
        router.navigate(to: "herdr/deleted")
        #expect(section == "herdr")
        #expect(agent == "")
        #expect(router.location == "herdr")
        #expect(router.history.current == "herdr")
        #expect(!router.canGoBack)
    }

    @Test func unregisterDropsTheSegment() {
        let router = WindowRouter()
        router.register(depth: 0, name: "section", value: "companion", accept: { _ in true }) {
            _ in
        }
        router.register(depth: 1, name: "tab", value: "chat", accept: { _ in true }) { _ in }
        router.unregister(depth: 1, name: "tab")
        #expect(router.location == "companion")
        #expect(router.history.current == "companion")
        #expect(!router.canGoBack)
    }

    @Test func anUnmountedChildSettlesAfterTheRestoreDeadline() async throws {
        let router = WindowRouter(restoreTimeout: 0.02)
        router.register(depth: 0, name: "section", value: "companion", accept: { _ in true }) {
            _ in
        }
        router.register(depth: 1, name: "tab", value: "", accept: { _ in true }) { _ in }
        router.navigate(to: "companion/chat/detail")
        #expect(router.restoring)
        #expect(router.location == "companion/chat/detail")
        router.unregister(depth: 1, name: "tab")
        #expect(router.restoring)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!router.restoring)
        #expect(router.location == "companion")
        #expect(router.history.entries == ["companion"])
    }

    @Test func aRestoreWithoutItsChildSettlesOnTheMountedRoute() async throws {
        let router = WindowRouter(restoreTimeout: 0.02)
        router.register(depth: 0, name: "section", value: "home", accept: { _ in true }) { _ in }
        router.navigate(to: "companion/chat")
        #expect(router.restoring)
        #expect(router.location == "companion/chat")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!router.restoring)
        #expect(router.location == "companion")
        #expect(router.history.entries == ["home", "companion"])
        router.goBack()
        #expect(router.location == "home")
        router.goForward()
        #expect(router.location == "companion")
    }

    @Test func evaluatingAnAnchorDoesNotMutateHistory() {
        let router = WindowRouter()
        let section = RouteSlotAnchor(
            depth: 0, name: "section", value: "companion", accept: { _ in true }, apply: { _ in },
            installedRouter: router)
        let tab = RouteSlotAnchor(
            depth: 1, name: "tab", value: "chat", accept: { _ in true }, apply: { _ in },
            installedRouter: router)
        _ = section.body
        _ = tab.body
        #expect(router.history.entries.isEmpty)
        NavigationRouteMount.sync(
            router: router, depth: 0, name: "section", value: "companion", accept: { _ in true },
            apply: { _ in })
        NavigationRouteMount.sync(
            router: router, depth: 1, name: "tab", value: "chat", accept: { _ in true },
            apply: { _ in })
        tab.unmount()
        section.unmount()
        #expect(router.location.isEmpty)
        #expect(router.history.current == "")
    }

    @Test func backAndForwardAcrossPagesIgnoresOutgoingChildSlots() {
        let router = WindowRouter()
        var outgoingWrites: [String] = []
        let companionOwner = UUID()
        let attentionOwner = UUID()
        router.register(depth: 0, name: "section", value: "companion", accept: { _ in true }) { _ in
        }
        router.register(
            depth: 1, name: "tab", value: "chat", owner: companionOwner, accept: { $0 == "chat" }
        ) { _ in }
        router.userChanged(depth: 0, name: "section", value: "attention", accept: { _ in true }) {
            _ in
        }
        router.unregister(depth: 1, name: "tab", owner: companionOwner)
        router.register(
            depth: 1, name: "tab", value: "overview", owner: attentionOwner,
            accept: { $0 == "overview" }
        ) { outgoingWrites.append($0) }
        let entries = router.history.entries
        router.goBack()
        #expect(router.location == "companion/chat")
        #expect(router.restoring)
        #expect(outgoingWrites.isEmpty)
        router.sync(
            depth: 1, name: "tab", value: "overview", owner: attentionOwner,
            accept: { $0 == "overview" }
        ) { outgoingWrites.append($0) }
        router.register(
            depth: 1, name: "tab", value: "chat", owner: companionOwner, accept: { $0 == "chat" }
        ) { _ in }
        router.unregister(depth: 1, name: "tab", owner: attentionOwner)
        #expect(!router.restoring)
        #expect(router.history.entries == entries)
        router.goForward()
        router.register(
            depth: 1, name: "tab", value: "overview", owner: attentionOwner,
            accept: { $0 == "overview" }
        ) { _ in }
        router.unregister(depth: 1, name: "tab", owner: companionOwner)
        #expect(router.location == "attention/overview")
        #expect(router.history.entries == entries)
        #expect(!router.lastRestoreRejected)
    }

    @Test func leavingAChildRouteDoesNotClearOrApplyForeignValues() {
        let router = WindowRouter()
        var writes: [String] = []
        router.register(depth: 0, name: "section", value: "dashboard", accept: { _ in true }) { _ in
        }
        router.userChanged(depth: 0, name: "section", value: "music", accept: { _ in true }) { _ in
        }
        router.register(depth: 1, name: "place", value: "library", accept: { _ in true }) {
            writes.append($0)
        }
        router.goBack()
        #expect(router.location == "dashboard")
        #expect(writes.isEmpty)
        #expect(router.history.entries == ["dashboard", "music/library"])
    }

    @Test func aPersistentChildRejoinsWhenItsParentScopeChanges() {
        let router = WindowRouter()
        let owner = UUID()
        router.register(depth: 0, name: "editor", value: "image", accept: { _ in true }) { _ in }
        router.register(
            depth: 1, name: "tab", value: "adjust", owner: owner, scope: ["image"],
            accept: { _ in true }
        ) { _ in }
        router.navigate(to: "video/timeline")
        #expect(router.restoring)
        router.sync(
            depth: 1, name: "tab", value: "default", owner: owner, scope: ["video"],
            accept: { _ in true }
        ) { _ in }
        #expect(!router.restoring)
        #expect(router.location == "video/timeline")
    }

    @Test(arguments: ["look", "background"])
    func aPersistentInspectorRejoinsUserSelectedSceneWithoutAddingHistory(inspectorValue: String) {
        let router = WindowRouter()
        let owner = UUID()
        let firstScene = UUID().uuidString
        let secondScene = UUID().uuidString
        var scene = firstScene
        var inspector = "look"
        let acceptsInspector: (String) -> Bool = {
            FixtureInspectorTab(rawValue: $0) != nil
        }
        router.register(depth: 0, name: "section", value: "camera", accept: { $0 == "camera" }) {
            _ in
        }
        router.register(
            depth: 1, name: "scene", value: scene, scope: ["camera"],
            accept: { $0 == firstScene || $0 == secondScene }
        ) { scene = $0 }
        router.register(
            depth: 2, name: "inspector", value: inspector, owner: owner,
            scope: ["camera", firstScene], accept: acceptsInspector
        ) { inspector = $0 }
        scene = secondScene
        router.sync(
            depth: 1, name: "scene", value: scene, scope: ["camera"],
            accept: { $0 == firstScene || $0 == secondScene }
        ) { scene = $0 }
        #expect(!router.restoring)
        #expect(router.history.current == "camera/\(secondScene)")
        inspector = inspectorValue
        router.sync(
            depth: 2, name: "inspector", value: inspector, owner: owner,
            scope: ["camera", secondScene], accept: acceptsInspector
        ) { inspector = $0 }
        let sceneEntries = ["camera/\(firstScene)/look", "camera/\(secondScene)/\(inspectorValue)"]
        #expect(router.history.entries == sceneEntries)
        #expect(router.history.current == router.location)
        inspector = "output"
        router.sync(
            depth: 2, name: "inspector", value: inspector, owner: owner,
            scope: ["camera", secondScene], accept: acceptsInspector
        ) { inspector = $0 }
        let entries = sceneEntries + ["camera/\(secondScene)/output"]
        router.goBack()
        #expect(!router.restoring)
        #expect(scene == secondScene)
        #expect(inspector == inspectorValue)
        #expect(router.location == sceneEntries.last)
        #expect(router.history.entries == entries)
        #expect(router.canGoForward)
        router.goForward()
        #expect(!router.restoring)
        #expect(inspector == "output")
        #expect(router.history.current == router.location)
        #expect(router.history.entries == entries)
    }

    @Test func anAlreadyUpdatedChildIsNotInvalidatedByItsParentSync() {
        let router = WindowRouter()
        router.register(depth: 0, name: "section", value: "companion", accept: { _ in true }) { _ in
        }
        router.register(
            depth: 1, name: "tab", value: "overview", scope: ["attention"], accept: { _ in true }
        ) { _ in }
        router.sync(depth: 0, name: "section", value: "attention", accept: { _ in true }) { _ in }
        #expect(router.location == "attention/overview")
    }

    @Test func aDelayedChildCanCompleteRestoreAfterSeveralRunLoopTurns() async throws {
        let router = WindowRouter()
        router.register(depth: 0, name: "section", value: "home", accept: { _ in true }) { _ in }
        router.navigate(to: "companion/chat")
        try await Task.sleep(for: .milliseconds(30))
        router.register(depth: 1, name: "tab", value: "chat", accept: { _ in true }) { _ in }
        #expect(!router.restoring)
        #expect(router.history.current == "companion/chat")
    }

    @Test func anUnreadySlotWaitsWithoutRejectingOrWriting() {
        let router = WindowRouter()
        var tab = ""
        router.register(depth: 0, name: "section", value: "database", accept: { _ in true }) { _ in
        }
        router.register(
            depth: 1, name: "connection", value: tab, ready: false, accept: { _ in false }
        ) { tab = $0 }
        router.navigate(to: "database/loaded")
        #expect(router.restoring)
        #expect(!router.lastRestoreRejected)
        #expect(tab.isEmpty)
        router.sync(
            depth: 1, name: "connection", value: tab, ready: true, accept: { $0 == "loaded" }
        ) { tab = $0 }
        #expect(tab == "loaded")
        #expect(!router.restoring)
        #expect(router.history.current == "database/loaded")
    }

    @Test func explicitReadinessOutlastsTheMissingChildDeadline() async throws {
        let router = WindowRouter(restoreTimeout: 0.02)
        router.register(depth: 0, name: "section", value: "database", accept: { _ in true }) { _ in
        }
        router.register(
            depth: 1, name: "connection", value: "", ready: false, accept: { _ in true }
        ) { _ in }
        router.navigate(to: "database/loaded/query")
        try await Task.sleep(for: .milliseconds(50))
        #expect(router.restoring)
        #expect(router.history.current == "database/loaded/query")
        router.sync(depth: 1, name: "connection", value: "", ready: true, accept: { _ in true }) {
            _ in
        }
        #expect(router.restoring)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!router.restoring)
        #expect(router.history.current == "database/loaded")
    }

    @Test func returningToHerdrBoardWaitsForTheSelectedTabToBecomeReady() async throws {
        let router = WindowRouter(restoreTimeout: 0.02)
        let owner = UUID()
        var tab = "fixture-tab"
        var writes: [String] = []
        router.register(depth: 0, name: "section", value: "herdr", accept: { $0 == "herdr" }) {
            _ in
        }
        router.register(
            depth: 1, name: "tab", value: tab, owner: owner, ready: false, scope: ["herdr"],
            accept: { $0.isEmpty || $0 == "fixture-tab" }
        ) {
            tab = $0
            writes.append($0)
        }
        router.navigate(to: "herdr")
        #expect(router.restoring)
        #expect(tab == "fixture-tab")
        #expect(writes.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(router.restoring)
        #expect(router.history.current == "herdr")
        #expect(tab == "fixture-tab")
        #expect(writes.isEmpty)
        router.sync(
            depth: 1, name: "tab", value: tab, owner: owner, ready: true, scope: ["herdr"],
            accept: { $0.isEmpty || $0 == "fixture-tab" }
        ) {
            tab = $0
            writes.append($0)
        }
        #expect(!router.restoring)
        #expect(!router.lastRestoreRejected)
        #expect(tab.isEmpty)
        #expect(writes == [""])
        #expect(router.location == "herdr")
        #expect(router.history.entries == ["herdr/fixture-tab", "herdr"])
        router.goBack()
        #expect(tab == "fixture-tab")
        #expect(router.location == "herdr/fixture-tab")
        router.goForward()
        #expect(tab.isEmpty)
        #expect(router.location == "herdr")
        #expect(router.history.entries == ["herdr/fixture-tab", "herdr"])
    }

    @Test func aParentOnlyRestoreSkipsAnEmptyUnreadyDescendantBeforeClearingASelection() {
        let router = WindowRouter()
        var inspector = "look"
        var emptyWrites: [String] = []
        router.register(depth: 0, name: "section", value: "camera", accept: { $0 == "camera" }) {
            _ in
        }
        router.register(
            depth: 1, name: "scene", value: "", ready: false, scope: ["camera"],
            accept: { _ in false }
        ) { emptyWrites.append($0) }
        router.register(
            depth: 2, name: "inspector", value: inspector, scope: ["camera", ""],
            accept: { $0.isEmpty || FixtureInspectorTab(rawValue: $0) != nil }
        ) { inspector = $0 }
        router.navigate(to: "camera")
        #expect(!router.restoring)
        #expect(inspector.isEmpty)
        #expect(emptyWrites.isEmpty)
        #expect(router.location == "camera")
        #expect(router.history.current == "camera")
    }

    @Test func aRejectedHistoryEntryDoesNotDestroyTheStack() {
        let router = WindowRouter()
        router.register(depth: 0, name: "section", value: "docs", accept: { _ in true }) { _ in }
        router.userChanged(depth: 0, name: "section", value: "home", accept: { $0 == "home" }) {
            _ in
        }
        router.goBack()
        #expect(router.lastRestoreRejected)
        #expect(router.location == "home")
        #expect(router.history.entries == ["docs", "home"])
        #expect(router.history.index == 1)
    }

    @Test func routersStayScopedToTheirOwnWindows() {
        let first = TestWindowHost.window(contentRect: .zero)
        let second = TestWindowHost.window(contentRect: .zero)
        let unrouted = TestWindowHost.window(contentRect: .zero)
        let main = WindowRouter()
        let auxiliary = WindowRouter()
        defer { main.detach(); auxiliary.detach() }
        main.attach(first, role: .main)
        auxiliary.attach(second, role: .auxiliary)
        #expect(WindowRouter.router(for: first) === main)
        #expect(WindowRouter.router(for: second) === auxiliary)
        #expect(WindowRouter.router(for: unrouted) == nil)
    }

    @Test func commandsMoveHistoryWithoutAKeyWindow() {
        let router = WindowRouter()
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 20))
        defer { window.orderOut(nil) }
        router.attach(window, role: .main)
        router.register(depth: 0, name: "section", value: "home", accept: { _ in true }) { _ in }
        router.userChanged(depth: 0, name: "section", value: "docs", accept: { _ in true }) { _ in
        }
        let moved = NavigationCommands.perform(action: "back", route: nil)
        #expect(moved["ok"] as? Bool == true)
        #expect(moved["route"] as? String == "home")
        #expect(NSApp.keyWindow !== window)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let gone = NavigationCommands.perform(action: "back", route: nil)
        #expect(gone["ok"] as? Bool == false)
        router.detach()
    }

    @Test func rejectedNavigationKeepsTheCurrentRoute() {
        let router = WindowRouter()
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 20, height: 20))
        defer {
            router.detach()
            window.orderOut(nil)
        }
        router.attach(window, role: .main)
        router.register(
            depth: 0, name: "section", value: "home",
            accept: { $0.isEmpty || $0 == "home" }
        ) { _ in }
        let reply = NavigationCommands.perform(action: "navigate", route: "companion/chat")
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["route"] as? String == "home")
        #expect(router.location == "home")
        #expect(!router.canGoBack)
        #expect(router.history.current == "home")
    }

    @Test func navigationKeepsANestedRouteBeforeItsChildMounts() {
        let router = WindowRouter()
        router.register(
            depth: 0, name: "section", value: "home",
            accept: { $0.isEmpty || $0 == "home" || $0 == "companion" }
        ) { _ in }
        router.navigate(to: "companion/chat")
        #expect(router.location == "companion/chat")
        #expect(router.canGoBack)
        router.goBack()
        #expect(router.location == "home")
    }

    @Test func hiddenHostPublishesAndMovesTheRoute() async throws {
        let router = WindowRouter()
        var readinessCompletions = 0
        let host = NSHostingView(
            rootView: HiddenRouteProbe(router: router, onReady: { readinessCompletions += 1 })
                .environment(\.automaticViewActionsEnabled, false))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer {
            router.detach()
            window.orderOut(nil)
        }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await settleHiddenRoute(router, location: "home", host: host)
        #expect(WindowRouter.router(for: window) === router)
        #expect(!window.isVisible)
        #expect(!router.restoring)
        #expect(router.history.entries == ["home"])
        let current = NavigationCommands.perform(action: "route", route: nil)
        #expect(current["route"] as? String == "home")
        #expect(current["canGoBack"] as? Bool == false)
        let moved = NavigationCommands.perform(action: "navigate", route: "companion/chat")
        try await settleHiddenRoute(router, location: "companion/chat", host: host)
        #expect(!router.restoring)
        #expect(readinessCompletions == 1)
        #expect(router.history.entries == ["home", "companion/chat"])
        let settled = NavigationCommands.perform(action: "route", route: nil)
        #expect(moved["ok"] as? Bool == true)
        #expect(settled["route"] as? String == "companion/chat")
        #expect(settled["canGoBack"] as? Bool == true)
        let back = NavigationCommands.perform(action: "back", route: nil)
        #expect(back["ok"] as? Bool == true)
        #expect(back["route"] as? String == "home")
        try await settleHiddenRoute(router, location: "home", host: host)
        let forward = NavigationCommands.perform(action: "forward", route: nil)
        #expect(forward["ok"] as? Bool == true)
        #expect(forward["route"] as? String == "companion/chat")
        try await settleHiddenRoute(router, location: "companion/chat", host: host)
        #expect(!router.restoring)
        #expect(readinessCompletions == 2)
        #expect(router.history.entries == ["home", "companion/chat"])
        #expect(router.history.current == "companion/chat")
        #expect(!window.isVisible)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    private func settleHiddenRoute(_ router: WindowRouter, location: String, host: NSView)
        async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if !router.restoring && router.location == location { return }
        } while clock.now < deadline
    }
}

@MainActor
private struct HiddenRouteProbe: View {
    let router: WindowRouter
    let onReady: () -> Void
    @State private var section = "home"
    @State private var tab = "chat"

    var body: some View {
        NavigationRouteHost(router: router, role: .main) {
            VStack {
                Text(section)
                if section == "companion" {
                    Text(tab).navigationRoute(
                        "tab", selection: $tab,
                        isReady: {
                            await Task.yield()
                            onReady()
                        })
                }
            }
            .navigationRoute(
                "section", selection: $section,
                isValid: { $0.isEmpty || $0 == "home" || $0 == "companion" }
            )
            .frame(width: 320, height: 180)
        }
    }
}

@MainActor
private struct RouteProbe: View {
    let router: WindowRouter
    let tab: String

    var body: some View {
        NavigationRouteHost(router: router) {
            Text(tab)
                .navigationRoute("tab", selection: .constant(tab))
                .navigationRoute("section", selection: .constant("companion"))
        }
    }
}

@Suite @MainActor struct NavigationShortcutGateTests {
    @Test func commandBracketsAreHistoryKeys() {
        #expect(NavigationShortcutGate.direction(keyCharacter: "[", modifiers: .command) == .back)
        #expect(
            NavigationShortcutGate.direction(keyCharacter: "]", modifiers: .command) == .forward)
        #expect(
            NavigationShortcutGate.direction(
                keyCharacter: "[", modifiers: [.command, .shift]) == nil)
        #expect(NavigationShortcutGate.direction(keyCharacter: "a", modifiers: .command) == nil)
    }

    @Test func mouseBackAndForwardAreButtonsThreeAndFour() {
        #expect(NavigationShortcutGate.direction(buttonNumber: 3) == .back)
        #expect(NavigationShortcutGate.direction(buttonNumber: 4) == .forward)
        #expect(NavigationShortcutGate.direction(buttonNumber: 2) == nil)
    }

    @Test func terminalsAndWebViewsAllowHistoryWhileEditorsKeepTheirShortcuts() {
        #expect(
            NavigationShortcutGate.allowsHistory(
                responder: NavigationGhosttyTerminalView(frame: .zero)))
        #expect(
            NavigationShortcutGate.allowsHistory(
                responder: NavigationWKWebView(frame: .zero)))
        let field = NSTextView(frame: .zero)
        field.isEditable = true
        field.isFieldEditor = true
        #expect(NavigationShortcutGate.allowsHistory(responder: field))
    }

    @Test func anEditableTextViewBlocksHistoryAndAPlainViewDoesNot() {
        let editor = NSTextView(frame: .zero)
        editor.isEditable = true
        #expect(!NavigationShortcutGate.allowsHistory(responder: editor))
        let label = NSView(frame: .zero)
        #expect(NavigationShortcutGate.allowsHistory(responder: label))
    }
}

private final class NavigationGhosttyTerminalView: NSView {}
private final class NavigationWKWebView: NSView {}

private enum FixtureInspectorTab: String {
    case audio, voice, devices, frame, look, background, overlays, output
}
