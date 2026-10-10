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

    @Test func actualUnshownMainWindowCloseWithdrawsItsWorkspaceAndPanelRelationship() async throws
    {
        let main = window("EdithMainWindow")
        let panel = window("EdithNotchPanel")
        defer { main.close(); panel.close() }
        let navigation = HostWindowNavigation(activeVersions: { [:] })
        let fixture = Lifecycle()
        let startup = HostNotchStartup(navigation: navigation) {
            fixture.context = $0; return fixture
        }
        await startup.settled()
        let token = navigation.register(window: main, apply: { _ in }, selected: { "home" })
        await startup.settled()
        let association = try fixture.context!.association.associate(panel)
        main.close()
        await startup.settled()
        #expect(navigation.registeredMainWorkspace == nil)
        #expect(navigation.owningWorkspace(for: panel) == nil)
        #expect(fixture.availability == [false, true, false])
        navigation.unregister(token)
        await startup.settled()
        #expect(fixture.availability == [false, true, false])
        fixture.context!.association.remove(association)
        try await startup.stop()
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

    @Test func actualFinalExistingWorkspaceAcknowledgementPrecedesOneExactCollapse() async throws {
        let main = window("EdithMainWindow")
        let panel = window("EdithNotchPanel")
        defer { main.close(); panel.close() }
        let suite = "notch-post-ack-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Lifecycle()
        fixture.panel = panel
        var selected = "home"
        var order: [String] = []
        let navigation = HostWindowNavigation(
            defaults: defaults,
            activeVersions: { ["calendar": "1.0.0"] },
            originatingWindow: { fixture.window(for: $0) },
            didApply: { _ in order.append("final-ack") })
        let startup = HostNotchStartup(navigation: navigation) {
            fixture.context = $0; return fixture
        }
        let token = navigation.register(
            window: main,
            apply: { route in
                order.append("apply"); selected = route.page
            }, selected: { selected })
        await startup.settled()
        let association = try fixture.context!.association.associate(panel)
        let ticket = try #require(
            startup.navigationTicket(
                presentationID: fixture.origin.cardPresentationID,
                providerID: "calendar", version: "1.0.0"))
        fixture.collapsed = { captured in
            #expect(order == ["apply", "final-ack"] && selected == "calendar")
            #expect(captured == ticket)
            order.append("collapse")
        }
        try await fixture.context!.navigate(fixture.origin, "calendar", "1.0.0")
        #expect(fixture.collapseCalls == 0)
        try await startup.navigationAcknowledged(ticket)
        #expect(order == ["apply", "final-ack", "collapse"] && fixture.collapseCalls == 1)
        fixture.context!.association.remove(association)
        navigation.unregister(token)
        try await startup.stop()
        #expect(!main.isVisible && !panel.isVisible)
    }

    @Test func rejectedAcknowledgementOrLateOriginWithdrawalCannotReachCollapse() async throws {
        let main = window("EdithMainWindow")
        let panel = window("EdithNotchPanel")
        defer { main.close(); panel.close() }
        let suite = "notch-post-ack-reject-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = Lifecycle()
        fixture.panel = panel
        let navigation = HostWindowNavigation(
            defaults: defaults,
            activeVersions: { ["calendar": "1.0.0"] },
            originatingWindow: { fixture.window(for: $0) })
        let startup = HostNotchStartup(navigation: navigation) {
            fixture.context = $0; return fixture
        }
        let token = navigation.register(
            window: main, apply: { _ in throw HostWindowNavigationError.routeRejected },
            selected: { "home" })
        await startup.settled()
        let association = try fixture.context!.association.associate(panel)
        let ticket = try #require(
            startup.navigationTicket(
                presentationID: fixture.origin.cardPresentationID,
                providerID: "calendar", version: "1.0.0"))
        await #expect(throws: HostWindowNavigationError.routeRejected) {
            try await fixture.context!.navigate(fixture.origin, "calendar", "1.0.0")
        }
        #expect(fixture.collapseCalls == 0)
        fixture.admitted = false
        await #expect(throws: HostWindowNavigationError.routeRejected) {
            try await startup.navigationAcknowledged(ticket)
        }
        fixture.admitted = true
        fixture.context!.association.remove(association)
        await #expect(throws: HostWindowNavigationError.routeRejected) {
            try await startup.navigationAcknowledged(ticket)
        }
        #expect(fixture.collapseCalls == 0)
        navigation.unregister(token)
        try await startup.stop()
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
    var admitted = true
    var collapseCalls = 0
    var collapsed: (HostNotchNavigationTicket) -> Void = { _ in }
    var panel: NSWindow?
    let origin = HostNotchCompactOrigin(
        identity: .init(ownershipID: UUID(), generation: UUID()), displayID: 1,
        panelPresentationID: UUID(), cardPresentationID: UUID(), tile: .init(.ability("calendar")))
    func navigationTicket(presentationID: UUID, providerID: String, version: String)
        -> HostNotchNavigationTicket?
    {
        guard admitted, presentationID == origin.cardPresentationID, providerID == "calendar",
            version == "1.0.0"
        else { return nil }
        return .init(
            identity: origin.identity, notchVersion: "1.0.0", displayID: origin.displayID,
            panelPresentationID: origin.panelPresentationID, presentationID: presentationID,
            providerID: providerID, providerVersion: version, revision: 1,
            slot: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                providerID: providerID, providerVersion: version, kind: .card, tile: origin.tile,
                rectangle: .init(x: 10, y: 40, width: 200, height: 200)),
            versions: [providerID: version])
    }
    func collapseAfterAcknowledgement(_ ticket: HostNotchNavigationTicket) async throws {
        collapseCalls += 1; collapsed(ticket)
    }
    func install() { installed += 1 }
    func owningWorkspaceChanged() async throws { availability.append(context!.available()) }
    func stop() async throws {
        stops += 1; if failStop { throw HostWindowNavigationError.unavailable }
    }
    func window(for presentationID: UUID) -> NSWindow? {
        presentationID == origin.cardPresentationID ? panel : nil
    }
    func compactVersions(_ value: HostNotchCompactOrigin) -> [String: String]? {
        admitted && value == origin ? ["calendar": "1.0.0"] : nil
    }
}
