import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostOriginalWorkerRoutingTests {
    private let owners = ["terminal", "clipboard", "emoji", "micMute", "systemStats"]

    @Test func terminalKeepsExistingNavigationShortcutPositionsAndSettingsOwnership() {
        #expect(
            Array(HostNavigationCatalog.pages.prefix(8).map(\.id))
                == [
                    "home", "machines", "docs", "agents", "dashboard", "herdr", "quinjet",
                    "companion",
                ])
        #expect(HostNavigationCatalog.route(extensionID: "jev") == nil)
        #expect(HostNavigationCatalog.route(extensionID: "notchShelf") == nil)
        #expect(HostExtensionSettingsPolicy.route(for: "notchShelf")?.section == "extension")
        #expect(
            HostNavigationCatalog.settings.first { $0.id == "terminal" }?.extensionID == nil)
    }

    @Test(arguments: ["terminal", "clipboard", "emoji", "micMute", "systemStats"])
    func originalUnsectionedRequestsSelectTheOwnedMainPageOrSettingsExport(id: String) throws {
        var visited: [String] = []
        let route = try HostWorkerNavigationRouting.resolve(
            extensionID: id, version: "1.0.0", activeVersions: admitted(id),
            visible: {
                visited.append($0); return true
            })
        #expect(route.page == (id == "terminal" ? "terminal" : "settings"))
        #expect(route.section == (id == "terminal" ? nil : id))
        #expect(visited == [route.page])
        #expect(route.relativePath == nil && route.presentationID == nil && route.location == nil)
        if id == "terminal" {
            let page = HostNavigationCatalog.page(route.page)
            #expect(page.extensionID == id && page.id != "extensions")
            #expect(HostTerminalUIRequest.accepts(.init(extensionID: id, location: "main")))
        } else {
            let settings = try #require(
                HostNavigationCatalog.settings.first { $0.id == route.section })
            #expect(settings.extensionID == id)
            let request = try #require(
                HostExtensionSettingsPolicy.request(
                    id: id, installed: package(id), state: .active, activeVersion: "1.0.0",
                    pendingDisable: false, pendingRemoval: false, systemVersion: 30))
            #expect(request.location == "settings" && request.section == "extension")
            #expect(request.extensionID == id)
        }
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
        for id in owners {
            for page in ["home", "extensions", "music", "downloads", "quinjet"] {
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
        for id in owners {
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

    @Test(arguments: ["terminal", "clipboard", "emoji", "micMute", "systemStats"])
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
        for id in owners {
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
