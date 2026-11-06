import AppKit
import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import HostWorkerFixtureSupport
import Observation
import QuartzCore
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostHomePerformanceTests {
    static let benchmark = ProcessInfo.processInfo.environment["EDITH_HOME_BENCHMARK"] != nil
    static let providers = ["music", "usage", "calendar", "keepAwake", "system"]
    static let sharedRunnerScale =
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ? 2.5 : 1.0

    static func budget(_ milliseconds: Double) -> Double { milliseconds * sharedRunnerScale }

    @Test func homeAppearsAndYieldsNavigationWithinTheMainThreadBudget() async throws {
        let runs = Self.benchmark ? 5 : 3
        var appear: [HomeBenchmarkResult] = []
        var leave: [HomeBenchmarkResult] = []
        for _ in 0..<runs {
            appear.append(try await measure(leaveAfter: nil))
            leave.append(try await measure(leaveAfter: .milliseconds(30)))
        }
        let shown = HomeBenchmarkResult.median(appear)
        let left = HomeBenchmarkResult.median(leave)
        print("home-appear: \(shown)")
        print("home-leave-while-loading: \(left)")
        #expect(shown.cards == 5, "\(shown)")
        #expect(left.cards == 0, "\(left)")
        #expect(shown.updatesPerCard <= 3, "\(shown)")
        #expect(shown.longestStallMs < Self.budget(60), "\(shown)")
        #expect(shown.busyMs < Self.budget(300), "\(shown)")
        #expect(shown.returnBusyMs < Self.budget(200), "\(shown)")
        #expect(shown.returnStallMs < Self.budget(65), "\(shown)")
        #expect(left.navigationMs < Self.budget(40), "\(left)")
        #expect(left.longestStallMs < Self.budget(60), "\(left)")
    }

    @Test func returningHomeReusesItsCardsInsteadOfRebuildingThem() async throws {
        let fixture = try await HomeBenchmarkFixture()
        let presenter = HomeBenchmarkPresenter()
        let route = HomeBenchmarkRoute()
        let window = fixture.window(route: route, presenter: presenter)
        defer { window.close(); fixture.clean() }
        try await settle(window) { presenter.connected == 5 }
        let created = presenter.created
        try await settle(window) { presenter.widthMismatches.isEmpty }
        for _ in 0..<3 {
            route.otherShown = false
            route.page = .other
            try await settle(window) { route.otherShown && presenter.connected == 0 }
            route.page = .home
            try await settle(window) { presenter.connected == 5 && presenter.visible == 5 }
            try await settle(window) { presenter.widthMismatches.isEmpty }
        }
        #expect(
            presenter.created == created,
            "created \(presenter.created) first \(created) parks \(presenter.parks) unparks \(presenter.unparks)"
        )
        #expect(await fixture.marketplace.sessions.shutdown())
    }

    private func measure(leaveAfter: Duration?) async throws -> HomeBenchmarkResult {
        let fixture = try await HomeBenchmarkFixture()
        let presenter = HomeBenchmarkPresenter()
        let route = HomeBenchmarkRoute()
        route.page = .other
        let window = fixture.window(route: route, presenter: presenter)
        defer { window.close(); fixture.clean() }
        try await settle(window) { route.otherShown }
        try await pump(window, for: .milliseconds(200))
        let meter = MainThreadMeter()
        meter.start()
        route.otherShown = false
        route.page = .home
        var navigationMs = 0.0
        if let leaveAfter {
            try await pump(window, for: leaveAfter)
            let left = CACurrentMediaTime()
            route.page = .other
            try await settle(window) { route.otherShown }
            navigationMs = (route.otherShownAt - left) * 1000
            try await pump(window, for: .milliseconds(600))
        } else {
            try await settle(window, timeout: .seconds(8)) { presenter.connected == 5 }
            try await pump(window, for: .milliseconds(600))
        }
        meter.stop()
        let cards = presenter.connected
        let updates = presenter.updates.values.max() ?? 0
        let revisit = MainThreadMeter()
        if leaveAfter == nil {
            route.otherShown = false
            route.page = .other
            try await settle(window) { route.otherShown && presenter.connected == 0 }
            try await pump(window, for: .milliseconds(200))
            revisit.start()
            route.page = .home
            try await settle(window) { presenter.connected == 5 && presenter.visible == 5 }
            try await pump(window, for: .milliseconds(400))
            revisit.stop()
        }
        route.page = .other
        try await settle(window) { presenter.connected == 0 }
        #expect(await fixture.marketplace.sessions.shutdown())
        return HomeBenchmarkResult(
            cards: cards, busyMs: meter.busyMs, longestStallMs: meter.longestMs,
            navigationMs: navigationMs,
            updatesPerCard: updates,
            returnBusyMs: revisit.busyMs, returnStallMs: revisit.longestMs)
    }

    private func pump(_ window: NSWindow, for duration: Duration) async throws {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle(
        _ window: NSWindow, timeout: Duration = .seconds(5), until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Home did not settle")
                throw HostWorkerError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

struct HomeBenchmarkResult: CustomStringConvertible {
    var cards: Int
    var busyMs: Double
    var longestStallMs: Double
    var navigationMs: Double
    var updatesPerCard: Int
    var returnBusyMs: Double
    var returnStallMs: Double

    static func median(_ results: [HomeBenchmarkResult]) -> HomeBenchmarkResult {
        func middle(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return HomeBenchmarkResult(
            cards: results.map(\.cards).min() ?? 0, busyMs: middle(results.map(\.busyMs)),
            longestStallMs: middle(results.map(\.longestStallMs)),
            navigationMs: middle(results.map(\.navigationMs)),
            updatesPerCard: results.map(\.updatesPerCard).max() ?? 0,
            returnBusyMs: middle(results.map(\.returnBusyMs)),
            returnStallMs: middle(results.map(\.returnStallMs)))
    }

    var description: String {
        String(
            format:
                "cards=%d busy=%.1fms longestStall=%.1fms navigation=%.1fms updatesPerCard=%d returnBusy=%.1fms returnStall=%.1fms",
            cards, busyMs, longestStallMs, navigationMs, updatesPerCard, returnBusyMs,
            returnStallMs)
    }
}

@MainActor final class MainThreadMeter {
    private var observer: CFRunLoopObserver?
    private var began: CFTimeInterval?
    private(set) var busyMs = 0.0
    private(set) var longestMs = 0.0

    func start() {
        began = CACurrentMediaTime()
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.record(activity) }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        record(.beforeWaiting)
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func record(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            began = now
        } else if let began {
            let elapsed = (now - began) * 1000
            busyMs += elapsed
            longestMs = max(longestMs, elapsed)
            self.began = nil
        }
    }
}

@MainActor @Observable final class HomeBenchmarkRoute {
    enum Page { case home, other }
    var page = Page.home
    @ObservationIgnored var otherShown = false
    @ObservationIgnored var otherShownAt: CFTimeInterval = 0
}

@MainActor @Observable final class HomeBenchmarkCardModel {
    var width: Double = 0
    let rows: Int
    init(rows: Int) { self.rows = rows }
}

private struct HomeBenchmarkCard: View {
    let model: HomeBenchmarkCardModel
    let title: String

    var body: some View {
        PageCard(title: title) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(0..<model.rows, id: \.self) { row in
                    HStack(alignment: .top, spacing: UIScale.pt(8)) {
                        RoundedRectangle(cornerRadius: UIScale.pt(4))
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: UIScale.pt(18), height: UIScale.pt(18))
                        Text(
                            "Synthetic \(title) row \(row) with enough words to wrap when the card is narrow"
                        )
                        .font(.edithText(.callout))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(width: model.width > 0 ? model.width : nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum HomeBenchmarkWork {
    static func spin(milliseconds: Double) {
        let end = CACurrentMediaTime() + milliseconds / 1000
        while CACurrentMediaTime() < end {}
    }
}

@MainActor final class HomeBenchmarkPresenter: HostExtensionContentPresenting {
    private(set) var created = 0
    private(set) var parks = 0
    private(set) var unparks = 0
    private(set) var updates: [UUID: Int] = [:]
    private var controllers: [UUID: HostRemoteViewController] = [:]
    private var parked: [(key: String, version: String, id: UUID, controller: NSViewController)] =
        []

    var connected: Int {
        controllers.values.filter { $0.connected && $0.isViewLoaded && $0.view.window != nil }
            .count
    }
    var visible: Int { controllers.values.filter { $0.connected && $0.state.visible }.count }
    var widthMismatches: [String] {
        controllers.values.filter { $0.connected && $0.isViewLoaded && $0.view.window != nil }
            .compactMap { controller in
                abs(controller.state.width - Double(controller.view.bounds.width)) < 1
                    ? nil : "\(controller.state.width) vs \(controller.view.bounds.width)"
            }
    }

    func controller(for request: HostExtensionContentRequest) async throws -> NSViewController {
        created += 1
        let model = HomeBenchmarkCardModel(rows: 6 + created % 4)
        let title = request.section ?? request.extensionID
        let id = request.presentationID
        let controller = HostRemoteViewController(
            request: request,
            present: { state in
                HomeBenchmarkWork.spin(milliseconds: 12)
                model.width = state.width
                let hosting = NSHostingController(
                    rootView: HomeBenchmarkCard(model: model, title: title))
                hosting.sizingOptions = [.intrinsicContentSize]
                return hosting
            },
            update: { [weak self] state in
                self?.updates[id, default: 0] += 1
                HomeBenchmarkWork.spin(milliseconds: 6)
                model.width = state.width
            })
        controllers[id] = controller
        return controller
    }

    func endPresentation(id: UUID) {
        parked.removeAll { $0.id == id }
        controllers.removeValue(forKey: id)?.detach()
    }

    func park(key: String, version: String, presentationID: UUID, controller: NSViewController) {
        parks += 1
        guard let remote = controllers[presentationID], remote === controller else {
            endPresentation(id: presentationID)
            return
        }
        remote.apply(compact: remote.state.compact, visible: false, width: remote.state.width)
        for entry in parked where entry.key == key { endPresentation(id: entry.id) }
        parked.removeAll { $0.key == key }
        parked.append((key, version, presentationID, controller))
    }

    func unpark(key: String, version: String) -> (
        presentationID: UUID, controller: NSViewController
    )? {
        unparks += 1
        guard let index = parked.lastIndex(where: { $0.key == key }) else { return nil }
        let entry = parked.remove(at: index)
        guard entry.version == version, controllers[entry.id] === entry.controller else {
            endPresentation(id: entry.id)
            return nil
        }
        return (entry.id, entry.controller)
    }
}

private struct HomeBenchmarkRoot: View {
    let marketplace: HostMarketplace
    let route: HomeBenchmarkRoute
    let presenter: HomeBenchmarkPresenter

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                ForEach(0..<14, id: \.self) { index in Text("Sidebar row \(index)") }
                Spacer()
            }
            .frame(width: 220)
            Group {
                switch route.page {
                case .home:
                    HostHomePage(
                        marketplace: marketplace, customize: { _ in }, extensions: {},
                        presenter: presenter)
                case .other:
                    PageScaffold {
                        PageHeader("Synthetic page")
                    } content: {
                        Text("Synthetic content")
                            .onAppear {
                                route.otherShown = true
                                route.otherShownAt = CACurrentMediaTime()
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.windowVisible, true)
        .environment(\.automaticViewActionsEnabled, true)
        .environment(\.surfaceSampleContent, true)
    }
}

@MainActor private struct HomeBenchmarkFixture {
    let directory: URL
    let marketplace: HostMarketplace
    let defaults: UserDefaults

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.home-benchmark-\(UUID().uuidString)",
            supportDirectory: directory)
        let store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
        defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
        let packages = HostHomePerformanceTests.providers.map { id in
            ExtensionPackage(
                id: id, version: "1.0.0", hostABI: HostContract.compatibility,
                downloadURL: URL(string: "https://example.invalid/\(id).zip")!,
                sha256: String(repeating: "a", count: 64), downloadBytes: 128,
                installedBytes: 128)
        }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        for package in packages {
            try FileManager.default.createDirectory(
                at: store.directory(for: package), withIntermediateDirectories: true)
        }
        try store.commit(packages)
        let key = Curve25519.Signing.PrivateKey()
        marketplace = try HostMarketplace(
            identity: identity, entries: HostIndex.bundled(), store: store,
            catalogClient: ExtensionCatalogClient(
                url: URL(string: "https://example.invalid/catalog")!,
                publicKey: key.publicKey.rawRepresentation,
                repository: MarketplaceConfiguration.repository,
                cache: directory.appendingPathComponent("catalog.json"),
                fetch: { _ in throw MarketplaceError.downloadFailed }),
            installer: ExtensionPackageInstaller(
                store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                verify: { _ in throw MarketplaceError.invalidSignature }),
            sessions: HostExtensionSessions(defaults: defaults) { package in
                HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    requestTimeout: .seconds(2),
                    engine: FixtureWorkerEngine.factory(mode: "normal"))
            })
        for id in HostHomePerformanceTests.providers { await marketplace.enable(id: id) }
    }

    func window(route: HomeBenchmarkRoute, presenter: HomeBenchmarkPresenter) -> NSWindow {
        _ = TestWindowHost.application
        let host = NSHostingView(
            rootView: HomeBenchmarkRoot(
                marketplace: marketplace, route: route, presenter: presenter
            )
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 1320, height: 860)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        return window
    }

    func clean() {
        let identity = marketplace.identity
        marketplace.surfaces.navigation.shutdown()
        marketplace.surfaces.requests.shutdown()
        marketplace.surfaces.privacy.shutdown()
        UserDefaults(suiteName: identity.identifier)?.removePersistentDomain(
            forName: identity.identifier)
        UserDefaults(suiteName: identity.defaultsSuite)?.removePersistentDomain(
            forName: identity.defaultsSuite)
        try? FileManager.default.removeItem(at: directory)
    }
}
