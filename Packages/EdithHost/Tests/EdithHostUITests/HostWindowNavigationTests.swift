import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostWindowNavigationTests {
    @Test func existingWindowAcknowledgesOnlyAfterSelectionAppliesWithoutShowingIt() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let gate = NavigationGate()
        var acknowledged = false
        let navigation = fixture.navigation(didApply: { _ in acknowledged = true })
        navigation.register(
            window: fixture.window,
            apply: { route in
                await gate.wait()
                try Task.checkCancellation()
                fixture.selected = route.page
            }, selected: { fixture.selected })
        let task = Task {
            try await navigation.navigate(extensionID: "calendar", version: "1.0.0")
        }
        await settle { gate.waiting }
        #expect(fixture.selected == "home")
        #expect(!acknowledged)
        gate.release()
        try await task.value
        #expect(fixture.selected == "calendar")
        #expect(acknowledged)
        #expect(!fixture.window.isVisible)
        #expect(!fixture.window.isKeyWindow)
    }

    @Test func absentOrAuxiliaryWindowCannotBeReplacedByAnImplicitNewWindow() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let navigation = fixture.navigation()
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(extensionID: "music", version: "1.0.0")
        }
        fixture.window.identifier = .init("EdithDetachedSection")
        fixture.register(navigation)
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(extensionID: "music", version: "1.0.0")
        }
        #expect(fixture.selected == "home")
        #expect(!fixture.window.isVisible)
    }

    @Test func missingPresentationWindowCannotAcknowledgeASelectionInAnotherWindow() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let navigation = fixture.navigation()
        fixture.register(navigation)
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(
                extensionID: "calendar", version: "1.0.0", presentationID: UUID(), location: "home")
        }
        #expect(fixture.selected == "home")
        #expect(!fixture.window.isVisible)
    }

    @Test func inactiveHiddenForeignAndUnboundedRoutesAreRejectedBeforeSelection() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let navigation = fixture.navigation()
        fixture.register(navigation)
        await #expect(throws: HostWindowNavigationError.inactiveOwner) {
            try await navigation.navigate(extensionID: "music", version: "2.0.0")
        }
        for (owner, page, path) in [
            ("calendar", "music", nil), ("music", "settings", nil),
            ("calendar", "calendar", "folder"), ("music", "music", "/tmp/foreign"),
            ("music", "music", "folder/../foreign"), ("music", "music", "~user/folder"),
            ("music", "music", String(repeating: "x", count: 4097)),
            ("music", "music", "folder//track"), ("music", "music", "folder/./track"),
            ("music", "music", "folder\\track"), ("music", "music", ""),
        ] as [(String, String, String?)] {
            await #expect(throws: HostWindowNavigationError.invalidDestination) {
                try await navigation.navigate(
                    extensionID: owner, version: "1.0.0", section: page, relativePath: path)
            }
        }
        fixture.defaults.set(false, forKey: "suiteMediaEnabled")
        await #expect(throws: HostWindowNavigationError.invalidDestination) {
            try await navigation.navigate(extensionID: "calendar", version: "1.0.0")
        }
        #expect(fixture.selected == "home")
    }

    @Test func explicitMusicFolderAndDownloadsKeepProviderOwnedRelativeContext() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        var routes: [HostWindowRoute] = []
        let navigation = fixture.navigation(
            originatingWindow: { _ in fixture.window }, didApply: { routes.append($0) })
        fixture.register(navigation)
        try await navigation.navigate(
            extensionID: "music", version: "1.0.0", relativePath: "Synthetic Album",
            presentationID: UUID(), location: "music.footer")
        #expect(fixture.selected == "music")
        #expect(routes.last?.relativePath == "Synthetic Album")
        try await navigation.navigate(
            extensionID: "music", version: "1.0.0", section: "downloads")
        #expect(fixture.selected == "downloads")
        fixture.versions["downloads"] = nil
        await #expect(throws: HostWindowNavigationError.invalidDestination) {
            try await navigation.navigate(
                extensionID: "music", version: "1.0.0", section: "downloads")
        }
    }

    @Test func originatingMainWindowWinsWithoutFocusingAnotherWindow() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let second = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 640, height: 480))
        second.isReleasedWhenClosed = false
        second.identifier = .init("EdithMainWindow")
        defer { second.close() }
        let origin = UUID()
        var secondSelection = "home"
        let navigation = HostWindowNavigation(
            defaults: fixture.defaults, activeVersions: { fixture.versions },
            originatingWindow: { $0 == origin ? fixture.window : nil })
        fixture.register(navigation)
        navigation.register(
            window: second, apply: { secondSelection = $0.page }, selected: { secondSelection })
        try await navigation.navigate(
            extensionID: "calendar", version: "1.0.0", presentationID: origin, location: "home")
        #expect(fixture.selected == "calendar")
        #expect(secondSelection == "home")
        #expect(!fixture.window.isVisible)
        #expect(!second.isVisible)
    }

    @Test func panelOriginRequiresExactExplicitWorkspaceRelationship() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let panel = TestWindowHost.window(contentRect: .zero)
        defer { panel.close() }
        let presentation = UUID()
        let navigation = fixture.navigation(originatingWindow: { $0 == presentation ? panel : nil })
        fixture.register(navigation)
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(
                extensionID: "calendar", version: "1.0.0", presentationID: presentation,
                location: "notch")
        }
        #expect(fixture.selected == "home")
        let relationship = try navigation.associate(window: panel, with: fixture.window)
        try await navigation.navigate(
            extensionID: "calendar", version: "1.0.0", presentationID: presentation,
            location: "notch")
        #expect(fixture.selected == "calendar")
        fixture.selected = "home"
        navigation.removeAssociation(relationship)
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(
                extensionID: "calendar", version: "1.0.0", presentationID: presentation,
                location: "notch")
        }
        #expect(fixture.selected == "home")
        #expect(!panel.isVisible && !fixture.window.isVisible)
    }

    @Test func cancellationOwnerReplacementAndDetachedRegistrationNeverAcknowledge() async throws {
        for change in ["cancel", "replace", "detach"] {
            let fixture = NavigationFixture()
            let gate = NavigationGate()
            var acknowledged = false
            let navigation = fixture.navigation(didApply: { _ in acknowledged = true })
            let token = navigation.register(
                window: fixture.window,
                apply: { route in
                    await gate.wait()
                    try Task.checkCancellation()
                    fixture.selected = route.page
                }, selected: { fixture.selected })
            let task = Task {
                try await navigation.navigate(extensionID: "calendar", version: "1.0.0")
            }
            await settle { gate.waiting }
            if change == "cancel" { task.cancel() }
            if change == "replace" { fixture.versions["calendar"] = "2.0.0" }
            if change == "detach" { navigation.unregister(token) }
            gate.release()
            do { try await task.value; Issue.record("A retired route acknowledged success") } catch
            {}
            #expect(!acknowledged)
            if change == "cancel" { #expect(fixture.selected == "home") }
            fixture.finish()
        }
    }

    @Test func actualMainWindowSentinelRegistersUpdatesAndWithdrawsItsRoute() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        let navigation = fixture.navigation()
        let sentinel = HostWindowNavigationView(
            navigation: navigation, apply: { fixture.selected = $0.page },
            selected: { fixture.selected })
        let container = NSView()
        container.addSubview(sentinel)
        fixture.window.contentView = container
        try await navigation.navigate(extensionID: "calendar", version: "1.0.0")
        #expect(fixture.selected == "calendar")
        sentinel.removeFromSuperview()
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(extensionID: "music", version: "1.0.0")
        }
        #expect(!fixture.window.isVisible)
    }

    @Test func maintenanceDefaultRoutePreservesItsOriginalSelectedSection() async throws {
        let fixture = NavigationFixture()
        defer { fixture.finish() }
        fixture.versions["cleaner"] = "1.0.0"
        var received: HostWindowRoute?
        let navigation = fixture.navigation(didApply: { received = $0 })
        fixture.register(navigation)
        try await navigation.navigate(extensionID: "cleaner", version: "1.0.0")
        #expect(fixture.selected == "appMaintenance")
        #expect(received?.section == "Cleaner")
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class NavigationFixture {
    let suite = "com.pulkit.edith.tests.window-navigation." + UUID().uuidString
    let defaults: UserDefaults
    let window: NSWindow
    var selected = "home"
    var versions = ["calendar": "1.0.0", "music": "1.0.0", "downloads": "1.0.0"]
    init() {
        defaults = UserDefaults(suiteName: suite)!
        window = TestWindowHost.window(contentRect: .init(x: 0, y: 0, width: 640, height: 480))
        window.isReleasedWhenClosed = false
        window.identifier = .init("EdithMainWindow")
    }
    func navigation(
        originatingWindow: @escaping @MainActor (UUID) -> NSWindow? = { _ in nil },
        didApply: @escaping @MainActor (HostWindowRoute) async throws -> Void = { _ in }
    ) -> HostWindowNavigation {
        HostWindowNavigation(
            defaults: defaults, activeVersions: { [weak self] in self?.versions ?? [:] },
            originatingWindow: originatingWindow, didApply: didApply)
    }
    func register(_ navigation: HostWindowNavigation) {
        navigation.register(
            window: window, apply: { [self] in selected = $0.page },
            selected: { [self] in selected })
    }
    func finish() { window.close(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class NavigationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
