import AppKit
import SwiftUI
import Testing

@testable import Edith

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
@Suite struct WindowRouterTests {
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
    }

    @Test func modifierRegistersWhileTheViewIsMounted() {
        let router = WindowRouter()
        let section = RouteSlotAnchor(
            depth: 0, name: "section", value: "companion", accept: { _ in true }, apply: { _ in },
            installedRouter: router)
        let tab = RouteSlotAnchor(
            depth: 1, name: "tab", value: "chat", accept: { _ in true }, apply: { _ in },
            installedRouter: router)
        _ = section.body
        _ = tab.body
        #expect(router.location == "companion/chat")
        tab.unmount()
        section.unmount()
        #expect(router.location.isEmpty)
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

@Suite struct NavigationShortcutGateTests {
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

    @Test func terminalsEditorsAndWebViewsKeepTheirOwnShortcuts() {
        #expect(
            !NavigationShortcutGate.allowsHistory(
                classNames: ["GhosttyTerminalView"], textRole: .none))
        #expect(
            !NavigationShortcutGate.allowsHistory(
                classNames: ["EdithTerminalView"], textRole: .none))
        #expect(
            !NavigationShortcutGate.allowsHistory(classNames: ["WKWebView"], textRole: .none))
        #expect(!NavigationShortcutGate.allowsHistory(classNames: ["NSView"], textRole: .editor))
        #expect(
            NavigationShortcutGate.allowsHistory(classNames: ["NSView"], textRole: .fieldEditor))
        #expect(NavigationShortcutGate.allowsHistory(classNames: ["NSView"], textRole: .none))
    }

    @Test func anEditableTextViewBlocksHistoryAndAPlainViewDoesNot() {
        let editor = NSTextView(frame: .zero)
        editor.isEditable = true
        #expect(!NavigationShortcutGate.allowsHistory(responder: editor))
        let label = NSView(frame: .zero)
        #expect(NavigationShortcutGate.allowsHistory(responder: label))
    }
}
