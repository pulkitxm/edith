import AppKit
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostOriginalWorkerRoutingTests {
    private let utilityOwners = ["clipboard", "emoji", "micMute", "systemStats"]
    private let owners = ["terminal", "clipboard", "emoji", "micMute", "systemStats"]

    @Test func completeOriginalCatalogsExcludeUtilityDestinationsAndKeepShortcutOrder() {
        #expect(
            HostNavigationCatalog.pages.map(\.id) == [
                "home", "machines", "docs", "agents", "dashboard", "herdr", "quinjet", "companion",
                "plugins", "appMaintenance", "blitztree", "system", "runningApps", "desk", "media",
                "studio", "latex", "timeLapse", "downloads", "music", "calendar", "virtualCamera",
                "data", "database", "attention", "seoAudit", "codeStats", "extensions", "settings",
                "about",
            ])
        #expect(
            HostNavigationCatalog.settings.map(\.id) == [
                "general", "surfaces", "agentActivity", "permissions", "agent", "jev", "data",
                "storage", "shortcuts", "terminal", "icloud", "updates",
            ])
        for id in owners { #expect(HostNavigationCatalog.route(extensionID: id) == nil) }
        #expect(HostNavigationCatalog.route(extensionID: "jev") == nil)
        #expect(HostNavigationCatalog.route(extensionID: "notchShelf") == nil)
        #expect(HostExtensionSettingsPolicy.route(for: "notchShelf")?.section == "extension")
        #expect(HostNavigationCatalog.settings.first { $0.id == "terminal" }?.extensionID == nil)
    }

    @Test func terminalFactoryRemainsInteractiveWithoutBecomingASidebarDestination() {
        #expect(HostTerminalUIRequest.accepts(.init(extensionID: "terminal", location: "main")))
        #expect(
            !HostTerminalUIRequest.accepts(.init(extensionID: "terminal", location: "settings")))
        #expect(throws: HostWindowNavigationError.invalidDestination) {
            try HostWorkerNavigationRouting.resolve(
                extensionID: "terminal", version: "1.0.0", activeVersions: admitted("terminal"),
                visible: { _ in true })
        }
    }

    @Test(arguments: ["clipboard", "emoji", "micMute", "systemStats"])
    func originalRequestsUseReviewRestoreAndSystemWithoutInventedSettings(id: String) throws {
        var visited: [String] = []
        let route = try HostWorkerNavigationRouting.resolve(
            extensionID: id, version: "1.0.0", activeVersions: admitted(id), currentPage: "music",
            visible: {
                visited.append($0); return true
            })
        let expectedPage =
            id == "micMute" ? "music" : (id == "systemStats" ? "system" : "extensions")
        #expect(route.page == expectedPage && route.section == nil)
        #expect(route.restoreOnly == (id == "micMute"))
        #expect(route.settingsExtensionID == (["clipboard", "emoji"].contains(id) ? id : nil))
        #expect(visited == [expectedPage])
        #expect(route.relativePath == nil && route.presentationID == nil && route.location == nil)
        let request = try #require(
            HostExtensionSettingsPolicy.request(
                id: id, installed: package(id), state: .active, activeVersion: "1.0.0",
                pendingDisable: false, pendingRemoval: false, systemVersion: 30))
        #expect(
            request.extensionID == id && request.location == "settings"
                && request.section == "extension")
    }

    @Test(arguments: ["terminal", "clipboard", "emoji", "micMute", "systemStats"])
    func absentReplacedIncompatibleAndRetiringWorkersNeverReachARegisteredDestination(id: String) {
        let candidates: [[String: String]] =
            [
                admitted(id, installed: [:]), admitted(id, versions: [id: "0.9.0"]),
                admitted(id, installed: [id: package("foreign")]),
                admitted(id, installed: [id: package(id, hostABI: "obsolete")]),
                admitted(id, installed: [id: package(id, architecture: "x86_64")]),
                admitted(id, installed: [id: package(id, minimumSystemVersion: 31)]),
                admitted(id, pendingDisable: [id]), admitted(id, pendingRemoval: [id]),
            ]
            + [HostActivationState.disabled, .starting, .stopping, .failed, .notInstalled].map {
                admitted(id, state: $0)
            }
        for versions in candidates {
            var visited = false
            #expect(versions.isEmpty)
            #expect(throws: HostWindowNavigationError.inactiveOwner) {
                try HostWorkerNavigationRouting.resolve(
                    extensionID: id, version: "1.0.0", activeVersions: versions,
                    visible: { _ in
                        visited = true; return true
                    })
            }
            #expect(!visited)
        }
    }

    @Test func utilityWorkersCannotBorrowAnotherOwnerPageOrMusicContext() {
        for id in utilityOwners {
            let owned = try? HostWorkerNavigationRouting.resolve(
                extensionID: id, version: "1.0.0", activeVersions: admitted(id),
                visible: { _ in true })
            for page in ["home", "extensions", "music", "downloads", "quinjet", "terminal"].filter({
                $0 != owned?.page || id == "micMute"
            }) {
                #expect(throws: HostWindowNavigationError.invalidDestination) {
                    try HostWorkerNavigationRouting.resolve(
                        extensionID: id, version: "1.0.0", section: page,
                        activeVersions: admitted(id), visible: { _ in true })
                }
            }
            #expect(throws: HostWindowNavigationError.invalidDestination) {
                try HostWorkerNavigationRouting.resolve(
                    extensionID: id, version: "1.0.0", relativePath: "Synthetic Album",
                    activeVersions: admitted(id), visible: { _ in true })
            }
            #expect(throws: HostWindowNavigationError.invalidDestination) {
                try HostWorkerNavigationRouting.resolve(
                    extensionID: id, version: "1.0.0", presentationID: UUID(),
                    location: "music.footer", activeVersions: admitted(id), visible: { _ in true })
            }
            #expect(throws: HostWindowNavigationError.invalidDestination) {
                try HostWorkerNavigationRouting.resolve(
                    extensionID: id, version: "1.0.0", activeVersions: admitted(id),
                    visible: { _ in false })
            }
        }
    }

    @Test func presentationIdentityAndOriginRemainPairedForOriginalRequests() throws {
        let token = UUID()
        for id in utilityOwners {
            let route = try HostWorkerNavigationRouting.resolve(
                extensionID: id, version: "1.0.0", presentationID: token, location: "home",
                activeVersions: admitted(id), visible: { _ in true })
            #expect(route.presentationID == token && route.location == "home")
            for (presentation, location) in [(token, nil), (nil, "home"), (token, "foreign")]
                as [(UUID?, String?)]
            {
                #expect(throws: HostWindowNavigationError.invalidDestination) {
                    try HostWorkerNavigationRouting.resolve(
                        extensionID: id, version: "1.0.0", presentationID: presentation,
                        location: location, activeVersions: admitted(id), visible: { _ in true })
                }
            }
        }
    }

    @Test(arguments: ["clipboard", "emoji", "micMute", "systemStats"])
    func workerClientAcknowledgesOnlyAfterItsOriginalDestinationApplies(id: String) async throws {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.original-navigation",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let configuration = HostWorkerConfiguration(
            identity: identity, extensionID: id, version: "1.0.0")
        var sent: HostWorkerNavigationRequest?
        var completed = false
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true }, send: { sent = $0 }, cancel: { _ in }
        )
        let token = client.navigate([:] as NSDictionary) { error in
            #expect(error == nil)
            completed = error == nil
        }
        #expect(token != nil && !completed)
        let request = try #require(sent)
        try request.validate(configuration: configuration)
        #expect(request.section == nil)
        let destination = try HostWorkerNavigationRouting.resolve(
            extensionID: request.extensionID, version: request.version, section: request.section,
            relativePath: request.relativePath, presentationID: request.presentationID,
            location: request.location, activeVersions: admitted(id), visible: { _ in true })
        let registration = SyntheticRegistration()
        await registration.apply(destination)
        #expect(registration.selected == destination)
        #expect(!completed)
        try HostWorkerNavigationRouting.validateApplied(
            extensionID: id, version: request.version, activeVersions: admitted(id),
            current: registration.selected == destination)
        try client.receive(HostWorkerNavigationReply(request: request, ok: true))
        #expect(completed)
    }

    @Test func replacedRetiringUnselectedAndHiddenDestinationsCannotAcknowledge() throws {
        for id in utilityOwners {
            let route = try HostWorkerNavigationRouting.resolve(
                extensionID: id, version: "1.0.0", activeVersions: admitted(id),
                visible: { _ in true })
            let registration = SyntheticRegistration()
            #expect(throws: HostWindowNavigationError.routeRejected) {
                try HostWorkerNavigationRouting.validateApplied(
                    extensionID: id, version: "1.0.0", activeVersions: admitted(id),
                    current: registration.selected == route)
            }
            #expect(throws: HostWindowNavigationError.routeRejected) {
                try HostWorkerNavigationRouting.validateApplied(
                    extensionID: id, version: "1.0.0", activeVersions: admitted(id), current: true,
                    visible: false)
            }
            for versions in [
                [id: "2.0.0"], admitted(id, pendingDisable: [id]),
                admitted(id, pendingRemoval: [id]),
            ] {
                #expect(throws: HostWindowNavigationError.inactiveOwner) {
                    try HostWorkerNavigationRouting.validateApplied(
                        extensionID: id, version: "1.0.0", activeVersions: versions, current: true)
                }
            }
        }
    }

    @Test func appliedSelectionCannotAcknowledgeAnUnpresentedWindow() {
        for id in owners {
            #expect(throws: HostWindowNavigationError.routeRejected) {
                try HostWorkerNavigationRouting.validateApplied(
                    extensionID: id, version: "1.0.0", activeVersions: admitted(id),
                    current: true, windowPresented: false)
            }
            for versions in [[id: "2.0.0"], admitted(id, pendingDisable: [id])] {
                #expect(throws: HostWindowNavigationError.inactiveOwner) {
                    try HostWorkerNavigationRouting.validateApplied(
                        extensionID: id, version: "1.0.0", activeVersions: versions,
                        current: true, windowPresented: true)
                }
            }
        }
    }

    @Test func showRestoresTheExactOriginAndLeavesItsSelectionForMicMute() async throws {
        let fixture = WindowFixture()
        defer { fixture.clean() }
        let second = TestWindowHost.window(contentRect: .zero)
        second.identifier = .init("EdithMainWindow")
        defer { second.close() }
        let presentation = UUID()
        var secondSelected = "home"
        var shown: [NSWindow] = []
        let navigation = HostWindowNavigation(
            defaults: fixture.defaults, activeVersions: { fixture.versions },
            originatingWindow: { $0 == presentation ? fixture.window : nil },
            showWindow: { shown.append($0) }, windowIsPresented: { shown.last === $0 })
        fixture.selected = "calendar"
        _ = navigation.register(
            window: fixture.window, apply: { _ in Issue.record("Mic Mute changed selection") },
            selected: { fixture.selected })
        _ = navigation.register(
            window: second, apply: { secondSelected = $0.page }, selected: { secondSelected })
        try await navigation.navigate(
            extensionID: "micMute", version: "1.0.0", presentationID: presentation, location: "home"
        )
        #expect(shown.count == 1 && shown[0] === fixture.window)
        #expect(fixture.selected == "calendar" && secondSelected == "home")
    }

    @Test func missingWorkspaceOpensWaitsForRegistrationThenShowsBeforeAcknowledgment() async throws
    {
        let fixture = WindowFixture()
        defer { fixture.clean() }
        var order: [String] = []
        var navigation: HostWindowNavigation!
        navigation = HostWindowNavigation(
            defaults: fixture.defaults, activeVersions: { fixture.versions },
            openWorkspace: {
                order.append("open")
                Task {
                    await Task.yield()
                    _ = navigation.register(
                        window: fixture.window,
                        apply: {
                            fixture.selected = $0.page; order.append("apply")
                        },
                        selected: { fixture.selected })
                }
            },
            showWindow: { window in
                #expect(window === fixture.window); order.append("show")
            }, windowIsPresented: { _ in order.last == "show" || order.last == "ack" },
            didApply: { _ in order.append("ack") })
        try await navigation.navigate(extensionID: "calendar", version: "1.0.0")
        #expect(order == ["open", "apply", "show", "ack"])
        #expect(fixture.selected == "calendar")
    }

    @Test func staleWorkersAndMissingPresentationOwnersCannotOpenAnotherWorkspace() async throws {
        let fixture = WindowFixture()
        defer { fixture.clean() }
        var opens = 0
        let navigation = HostWindowNavigation(
            defaults: fixture.defaults, activeVersions: { fixture.versions },
            openWorkspace: { opens += 1 })
        await #expect(throws: HostWindowNavigationError.inactiveOwner) {
            try await navigation.navigate(extensionID: "calendar", version: "0.9.0")
        }
        await #expect(throws: HostWindowNavigationError.unavailable) {
            try await navigation.navigate(
                extensionID: "calendar", version: "1.0.0", presentationID: UUID(), location: "home")
        }
        #expect(opens == 0)
    }

    @Test(arguments: ["replace", "reregister", "cancel", "hidden"])
    func windowDeliveryRacesCannotAcknowledge(change: String) async throws {
        let fixture = WindowFixture()
        defer { fixture.clean() }
        let gate = DeliveryGate()
        var acknowledged = false
        let navigation = HostWindowNavigation(
            defaults: fixture.defaults, activeVersions: { fixture.versions },
            showWindow: { _ in await gate.wait() }, windowIsPresented: { _ in change != "hidden" },
            didApply: { _ in acknowledged = true })
        let token = fixture.register(navigation)
        let task = Task { try await navigation.navigate(extensionID: "calendar", version: "1.0.0") }
        await settle { gate.waiting }
        if change == "replace" { fixture.versions["calendar"] = "2.0.0" }
        if change == "reregister" {
            navigation.unregister(token); _ = fixture.register(navigation)
        }
        if change == "cancel" { task.cancel() }
        gate.release()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!acknowledged)
    }

    @Test func terminalReusesOnlyItsExactWorkspaceAndFactoryThenReleasesOnClose() async throws {
        let fixture = TerminalWindowFixture()
        defer { fixture.clean() }
        let service = fixture.service()
        try await service.open(fixture.request())
        try await service.open(fixture.request())
        #expect(fixture.created.count == 1 && fixture.presentations == 2)
        #expect(fixture.loaded.count == 1 && fixture.loaded[0].extensionID == "terminal")
        #expect(fixture.loaded[0].location == "main" && fixture.loaded[0].section == nil)
        #expect(HostTerminalUIRequest.accepts(fixture.loaded[0]))
        #expect(fixture.associations.count == 1)
        fixture.ownerToken = UUID()
        try await service.open(fixture.request())
        #expect(fixture.created.count == 2 && fixture.loaded.count == 2)
        fixture.created[0].close()
        await settle { service.pendingCount == 1 }
        #expect(fixture.released == [fixture.loaded[0].presentationID])
        try await service.stop()
        #expect(service.pendingCount == 0 && fixture.released.count == 2)
        #expect(fixture.removedAssociations.count == 2)
    }

    @Test(arguments: ["replace", "owner", "cancel", "hidden"])
    func terminalReadinessRacesReleaseTheExactPresentation(change: String) async throws {
        let fixture = TerminalWindowFixture()
        defer { fixture.clean() }
        let gate = DeliveryGate()
        fixture.readyGate = gate
        let service = fixture.service()
        let task = Task { try await service.open(fixture.request()) }
        await settle { gate.waiting }
        #expect(service.pendingCount == 1 && fixture.released.isEmpty)
        if change == "replace" { fixture.available = false }
        if change == "owner" { fixture.ownerToken = UUID() }
        if change == "cancel" { task.cancel() }
        if change == "hidden" { fixture.presented = false }
        gate.release()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(service.pendingCount == 0)
        #expect(fixture.released == fixture.loaded.map(\.presentationID))
        #expect(fixture.removedAssociations.count == 1)
        try await service.stop()
    }

    @Test func terminalDisableDrainsAnOpeningFactoryAndRetainsFailedCleanupForRetry() async throws {
        let fixture = TerminalWindowFixture()
        defer { fixture.clean() }
        let gate = DeliveryGate()
        fixture.loadGate = gate
        let service = fixture.service()
        let open = Task { try await service.open(fixture.request()) }
        await settle { gate.waiting }
        let stop = Task { try await service.stop() }
        await Task.yield()
        gate.release()
        try await stop.value
        await #expect(throws: CancellationError.self) { try await open.value }
        #expect(fixture.created.isEmpty && service.pendingCount == 0 && fixture.released.count == 1)
        fixture.loadGate = nil
        try await service.open(fixture.request())
        fixture.releaseFails = true
        await #expect(throws: HostWorkerError.rejected) { try await service.stop() }
        #expect(service.pendingCount == 1)
        await #expect(throws: HostWorkerError.rejected) {
            try await service.open(fixture.request())
        }
        fixture.releaseFails = false
        try await service.stop()
        #expect(service.pendingCount == 0)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @MainActor private final class WindowFixture {
        let suite = "com.pulkit.edith.tests.original-window." + UUID().uuidString
        let defaults: UserDefaults
        let window = TestWindowHost.window(contentRect: .zero)
        var selected = "home"
        var versions = ["calendar": "1.0.0", "micMute": "1.0.0"]
        init() {
            defaults = UserDefaults(suiteName: suite)!
            window.identifier = .init("EdithMainWindow")
            window.isReleasedWhenClosed = false
        }
        func register(_ navigation: HostWindowNavigation) -> UUID {
            navigation.register(
                window: window, apply: { [self] in selected = $0.page },
                selected: { [self] in selected })
        }
        func clean() { window.close(); defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor private final class TerminalWindowFixture {
        let owner = TestWindowHost.window(contentRect: .zero)
        var ownerToken = UUID()
        var available = true
        var presented = true
        var releaseFails = false
        var created: [NSWindow] = []
        var loaded: [HostExtensionContentRequest] = []
        var released: [UUID] = []
        var associations: [UUID] = []
        var removedAssociations: [UUID] = []
        var presentations = 0
        var loadGate: DeliveryGate?
        var readyGate: DeliveryGate?
        func request() throws -> HostWorkerNavigationRequest {
            let identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.original-terminal",
                supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
            return .init(
                configuration: .init(identity: identity, extensionID: "terminal", version: "1.0.0"))
        }
        func service() -> HostTerminalWindows {
            let windows = HostSectionWindows(
                saveFrames: false,
                makeWindow: { [self] frame in
                    let window = TestWindowHost.window(contentRect: frame)
                    created.append(window); return window
                },
                present: { [self] window in
                    presentations += 1; window.contentView?.layoutSubtreeIfNeeded()
                }, visibleFrame: { .init(x: 0, y: 0, width: 1440, height: 900) }
            ) { _ in AnyView(EmptyView()) }
            return HostTerminalWindows(
                windows: windows,
                owner: { [self] _ in
                    let token = ownerToken
                    return .init(
                        token: token, window: owner,
                        validate: { [self] in
                            guard ownerToken == token, available else {
                                throw HostWorkerError.rejected
                            }
                        })
                },
                validateOrigin: { [self] request in
                    guard available, request.version == "1.0.0" else {
                        throw HostWorkerError.rejected
                    }
                },
                load: { [self] request in
                    loaded.append(request)
                    if let loadGate { await loadGate.wait() }
                    let controller = NSViewController()
                    controller.view = NSView(frame: .init(x: 0, y: 0, width: 880, height: 640))
                    return controller
                },
                ready: { [self] _, window in
                    window.contentView?.layoutSubtreeIfNeeded()
                    if let readyGate { await readyGate.wait() }
                },
                release: { [self] id in
                    if releaseFails { throw HostWorkerError.rejected }
                    released.append(id)
                },
                associate: { [self] _, workspace in
                    #expect(workspace === owner)
                    let token = UUID(); associations.append(token); return token
                }, removeAssociation: { [self] in removedAssociations.append($0) },
                presented: { [self] _ in presented })
        }
        func clean() { for window in created { window.close() }; owner.close() }
    }

    @MainActor private final class DeliveryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func admitted(
        _ id: String, installed: [String: ExtensionPackage]? = nil,
        state: HostActivationState = .active, versions: [String: String]? = nil,
        pendingDisable: Set<String> = [], pendingRemoval: Set<String> = []
    ) -> [String: String] {
        HostWorkerNavigationRouting.activeVersions(
            installed: installed ?? [id: package(id)], states: [id: state],
            versions: versions ?? [id: "1.0.0"], pendingDisable: pendingDisable,
            pendingRemoval: pendingRemoval, systemVersion: 30)
    }

    private func package(
        _ id: String, hostABI: String = HostContract.compatibility, architecture: String = "arm64",
        minimumSystemVersion: Int = 14
    ) -> ExtensionPackage {
        .init(
            id: id, version: "1.0.0", hostABI: hostABI, architecture: architecture,
            minimumSystemVersion: minimumSystemVersion,
            downloadURL: URL(string: "https://example.invalid/package.zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: 100, installedBytes: 200)
    }

    @MainActor private final class SyntheticRegistration {
        private(set) var selected: HostWindowRoute?
        func apply(_ route: HostWindowRoute) async {
            await Task.yield()
            selected = route
        }
    }
}
