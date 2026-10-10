import AppKit
import EdithExtensionSupport
import Foundation
import Testing
@testable import EdithHost

@MainActor @Suite(.serialized)
struct HostNotchStartupTests {
    @Test func exactRegistrationsNotifyWithoutOrderingAnyWindow() {
        let first = window("EdithMainWindow")
        let second = window("EdithMainWindow")
        let foreign = window("EdithDetachedSection")
        defer { first.close(); second.close(); foreign.close() }
        let navigation = HostWindowNavigation(activeVersions: { [:] })
        var changes: [UUID?] = []
        navigation.didChangeMainWorkspace = {
            changes.append(navigation.registeredMainWorkspace?.token)
        }
        let one = navigation.register(window: first, apply: { _ in }, selected: { "home" })
        let other = navigation.register(window: foreign, apply: { _ in }, selected: { "home" })
        let two = navigation.register(window: second, apply: { _ in }, selected: { "home" })
        navigation.unregister(other)
        navigation.unregister(UUID())
        navigation.unregister(two)
        navigation.unregister(one)
        #expect(changes == [one, two, one, nil])
        #expect(!first.isVisible && !second.isVisible && !foreign.isVisible)
    }

    @Test func unregisteringAnAlreadyRetiredWeakOwnerStillDeliversTheZeroWorkspaceState() {
        let navigation = HostWindowNavigation(activeVersions: { [:] })
        var changes: [UUID?] = []
        navigation.didChangeMainWorkspace = {
            changes.append(navigation.registeredMainWorkspace?.token)
        }
        var main: NSWindow? = window("EdithMainWindow")
        let token = navigation.register(window: main!, apply: { _ in }, selected: { "home" })
        main?.close()
        main = nil
        navigation.unregister(token)
        #expect(changes == [token, nil])
        #expect(navigation.registeredMainWorkspace == nil)
    }

    @Test func panelAssociationUsesOnlyTheExplicitRegisteredWorkspace() async throws {
        let main = window("EdithMainWindow")
        let panel = window("EdithNotchPanel")
        defer { main.close(); panel.close() }
        let navigation = HostWindowNavigation(activeVersions: { [:] })
        let fixture = Lifecycle()
        let startup = HostNotchStartup(navigation: navigation) {
            fixture.context = $0; return fixture
        }
        await startup.settled()
        #expect(fixture.installed == 1)
        #expect(fixture.availability == [false])
        #expect(throws: HostWindowNavigationError.unavailable) {
            try fixture.context!.association.associate(panel)
        }
        let token = navigation.register(window: main, apply: { _ in }, selected: { "home" })
        await startup.settled()
        let association = try fixture.context!.association.associate(panel)
        #expect(navigation.owningWorkspace(for: panel) === main)
        navigation.unregister(token)
        await startup.settled()
        #expect(fixture.availability == [false, true, false])
        #expect(navigation.owningWorkspace(for: panel) == nil)
        fixture.context!.association.remove(association)
        try await startup.stop()
        #expect(fixture.stops == 1)
        #expect(!main.isVisible && !panel.isVisible)
    }

    @Test func compactNavigationRejectsForeignGenerationAndRemovedOwnerBeforeAcknowledgement()
        async throws
    {
        let main = window("EdithMainWindow")
        let panel = window("EdithNotchPanel")
        defer { main.close(); panel.close() }
        let suite = "notch-startup-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Lifecycle()
        fixture.panel = panel
        var selected = "home"
        let navigation = HostWindowNavigation(
            defaults: defaults, activeVersions: { ["calendar": "1.0.0"] },
            originatingWindow: { fixture.window(for: $0) })
        let startup = HostNotchStartup(navigation: navigation) {
            fixture.context = $0; return fixture
        }
        let token = navigation.register(
            window: main, apply: { selected = $0.page }, selected: { selected })
        await startup.settled()
        let association = try fixture.context!.association.associate(panel)
        defer { fixture.context!.association.remove(association) }
        let origin = fixture.origin
        var forged = origin
        forged = .init(
            identity: .init(ownershipID: origin.identity.ownershipID, generation: UUID()),
            displayID: origin.displayID, panelPresentationID: origin.panelPresentationID,
            cardPresentationID: origin.cardPresentationID, tile: origin.tile)
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await fixture.context!.navigate(forged, "calendar", "1.0.0")
        }
        #expect(selected == "home")
        try await fixture.context!.navigate(origin, "calendar", "1.0.0")
        #expect(selected == "calendar")
        navigation.unregister(token)
        await startup.settled()
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await fixture.context!.navigate(origin, "calendar", "1.0.0")
        }
        try await startup.stop()
        #expect(!main.isVisible && !panel.isVisible)
    }

    @Test func failedDrainRetainsLifecycleForAnHonestRetry() async throws {
        let fixture = Lifecycle()
        let navigation = HostWindowNavigation(activeVersions: { [:] })
        let startup = HostNotchStartup(navigation: navigation) {
            fixture.context = $0; return fixture
        }
        await startup.settled()
        fixture.failStop = true
        await #expect(throws: HostWindowNavigationError.unavailable) { try await startup.stop() }
        #expect(fixture.stops == 1)
        #expect(navigation.didChangeMainWorkspace == nil)
        fixture.failStop = false
        try await startup.stop()
        #expect(fixture.stops == 2)
        #expect(!fixture.context!.available())
    }

    private func window(_ identifier: String) -> NSWindow {
        _ = NSApplication.shared
        let value = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        value.isReleasedWhenClosed = false
        value.identifier = .init(identifier)
        return value
    }
}

@MainActor private final class Lifecycle: HostNotchStartupLifecycle {
    var context: HostNotchStartupContext?
    var installed = 0
    var availability: [Bool] = []
    var stops = 0
    var failStop = false
    var panel: NSWindow?
    let origin = HostNotchCompactOrigin(
        identity: .init(ownershipID: UUID(), generation: UUID()), displayID: 1,
        panelPresentationID: UUID(), cardPresentationID: UUID(), tile: .init(.ability("calendar")))
    func install() { installed += 1 }
    func owningWorkspaceChanged() async throws { availability.append(context!.available()) }
    func stop() async throws {
        stops += 1; if failStop { throw HostWindowNavigationError.unavailable }
    }
    func window(for presentationID: UUID) -> NSWindow? {
        presentationID == origin.cardPresentationID ? panel : nil
    }
    func compactVersions(_ value: HostNotchCompactOrigin) -> [String: String]? {
        value == origin ? ["calendar": "1.0.0"] : nil
    }
}
