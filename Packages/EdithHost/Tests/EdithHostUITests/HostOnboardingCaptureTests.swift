import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import ExtensionMarketplace
import Foundation
import SwiftUI
import HostAccessibilityFixtureSupport
import Testing

@testable import EdithHost

@Suite(.serialized) @MainActor struct HostOnboardingCaptureTests {
    struct Variant {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let zoom: Double
        let scheme: ColorScheme
    }

    static let variants = [
        Variant(name: "regular-light", width: 1100, height: 760, zoom: 1, scheme: .light),
        Variant(name: "regular-dark", width: 1100, height: 760, zoom: 1, scheme: .dark),
        Variant(name: "compact-light", width: 640, height: 700, zoom: 1, scheme: .light),
        Variant(name: "compact-dark", width: 640, height: 700, zoom: 1, scheme: .dark),
        Variant(name: "zoom-light", width: 1100, height: 760, zoom: 1.6, scheme: .light),
        Variant(name: "wide-light", width: 1600, height: 960, zoom: 1, scheme: .light),
    ]

    @Test func welcomeStepInvitesAndOffersOneObviousStart() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        try await capture(model, stage: "welcome") { labels in
            #expect(labels.contains("Get started"))
            #expect(labels.contains("Restore from iCloud"))
            #expect(labels.contains(model.skipTitle))
        }
    }

    @Test func workflowStepOffersEverySuite() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.start()
        try await capture(model, stage: "workflows") { labels in
            for workflow in HostWorkflow.allCases { #expect(labels.contains(workflow.title)) }
        }
    }

    @Test func toolsStepShowsSizesOncePackagesAreKnown() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        try await capture(model, stage: "tools") { labels in
            #expect(labels.contains { $0.contains("to download") })
            #expect(labels.contains { $0.hasPrefix("Continue with") })
        }
    }

    @Test func toolsStepShowsPlaceholdersWhileSizesLoad() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.catalog = [:]
        fixture.hangRefresh = true
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.refreshCatalog()
        try await capture(model, stage: "tools-loading") { labels in
            #expect(labels.contains("Loading tools"))
            #expect(!labels.contains { $0.contains("unavailable") })
        }
        model.cancel()
    }

    @Test func toolsStepExplainsAFailedSizeCheckWithARetry() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.catalog = [:]
        fixture.refreshFailure = "The extension catalog could not be reached."
        let model = fixture.model()
        model.present()
        model.choose(.desk)
        model.refreshCatalog()
        await fixture.settle(model)
        try await capture(model, stage: "tools-error") { labels in
            #expect(labels.contains("Try again"))
            #expect(labels.contains { $0.contains("could not be reached") })
        }
    }

    @Test func permissionsStepShowsGrantedCurrentAndRelaunchStates() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.system.granted = [.calendar: true]
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        for id in ["calendar", "hinge", "keystrokeHighlight", "clipboard", "notchShelf"] {
            model.toggle(id)
        }
        model.continueFromTools()
        await model.permissions.refresh()
        _ = model.permissions.openSettings(.screenRecording)
        try await capture(model, stage: "permissions") { labels in
            #expect(labels.contains("Relaunch Edith"))
            #expect(labels.contains("Calendar"))
            #expect(labels.contains("Open System Settings"))
            #expect(!labels.contains("Allow Calendar"))
        }
    }

    @Test func installingStepShowsProgressPerTool() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.slowInstalls = ["hinge"]
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        for id in ["clipboard", "hinge", "emoji"] { model.toggle(id) }
        model.installSelection()
        for _ in 0..<100 where model.states["clipboard"] != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await capture(model, stage: "installing") { labels in
            #expect(labels.contains("Cancel setup"))
        }
        model.cancel()
        await fixture.settle(model)
    }

    @Test func installingStepExplainsFailuresWithARetry() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.failingInstalls = ["hinge"]
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        for id in ["clipboard", "hinge", "emoji"] { model.toggle(id) }
        model.installSelection()
        await fixture.settle(model)
        try await capture(model, stage: "installing-failed") { labels in
            #expect(labels.contains("Retry setup"))
        }
    }

    @Test func finishedStepListsWhereEachToolLives() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        for id in ["clipboard", "hinge", "calendar"] { model.toggle(id) }
        model.installSelection()
        await fixture.settle(model)
        #expect(model.stage == .finished)
        try await capture(model, stage: "finished") { labels in
            #expect(labels.contains("Start using Edith"))
        }
    }

    @Test func finishedStepWithoutToolsPointsToTheMarketplace() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.skip()
        try await capture(model, stage: "finished-empty") { labels in
            #expect(labels.contains("Start using Edith"))
        }
    }

    @Test func permissionsSettingsShowAllowedMissingAndRelaunchStates() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.system.granted = [.calendar: true, .notifications: true]
        let permissions = fixture.permissions()
        await permissions.refresh()
        _ = permissions.openSettings(.screenRecording)
        let active: Set<String> = ["calendar", "hinge", "clipboard", "usage", "notchShelf"]
        try await capturePane(
            permissions, active: active, filter: .mine, name: "permissions-settings"
        ) { labels in
            #expect(labels.contains("Relaunch Edith"))
            #expect(labels.contains { $0.contains("allowed for your tools") })
        }
        try await capturePane(
            permissions, active: [], filter: .mine, name: "permissions-settings-empty"
        ) { labels in
            #expect(labels.contains("Browse Extensions"))
        }
    }

    private func capturePane(
        _ permissions: HostPermissions, active: Set<String>, filter: HostPermissionFilter,
        name: String, verify: ([String]) -> Void
    ) async throws {
        let usages = permissions.usages(entries: CaptureFixture.entries, activeIDs: active)
        try await render(name: name, verify: verify) {
            PageWorkspace {
                PageHeader("Permissions") {
                    EmptyView()
                } accessory: {
                    PageSubtitle("Access your tools need from macOS.")
                }
            } content: {
                HostPermissionsList(
                    usages: usages, permissions: permissions, filter: .constant(filter))
            }
        }
    }

    private func capture(
        _ model: HostWorkflowOnboardingModel, stage: String,
        verify: ([String]) -> Void
    ) async throws {
        try await render(name: "onboarding-\(stage)", fit: true, verify: verify) {
            OnboardingCapturePage(model: model)
        }
    }

    private func render<Content: View>(
        name: String, fit: Bool = false, verify: ([String]) -> Void,
        @ViewBuilder content: () -> Content
    ) async throws {
        defer { UIScale.apply(1) }
        _ = TestWindowHost.application
        let accessibility = try HostAccessibilityFixture.enable()
        defer { for error in accessibility.restore() { Issue.record(error) } }
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            let compact = variant.width < UIScale.pt(720)
            let page = content()
                .environment(\.compactLayout, compact)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.controlActiveState, .key)
                .transaction { $0.animation = nil }
            let host = NSHostingView(rootView: page.frame(width: variant.width))
            host.frame = CGRect(x: 0, y: 0, width: variant.width, height: variant.height)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let height = fit ? max(variant.height, ceil(host.fittingSize.height)) : variant.height
            host.frame.size.height = height
            window.setContentSize(host.frame.size)
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(abs(host.bounds.width - variant.width) < 1)
            #expect(!TestWindowHost.isExposedOnDesktop(window))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0)
            if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: url.appendingPathComponent("\(name)-\(variant.name).png"),
                    options: .atomic)
            }
            if variant.zoom == 1 { verify(Self.labels(in: host)) }
            window.orderOut(nil)
        }
    }

    static func labels(in view: NSView) -> [String] {
        var found: [String] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 64 else { return }
            if let label = (element as AnyObject).accessibilityLabel?(), !label.isEmpty {
                found.append(label)
            }
            if let element = element as? NSObject,
                let value = element.value(forKey: "accessibilityValue") as? String, !value.isEmpty
            {
                found.append(value)
            }
            for child in (element as AnyObject).accessibilityChildren?() ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(view, depth: 0)
        return found
    }
}

struct OnboardingCapturePage: View {
    let model: HostWorkflowOnboardingModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader {
                Text("Good morning, Alex.")
            } accessory: {
                PageSubtitle("Thursday, November 5")
            }
            Divider()
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                HostWorkflowOnboardingView(model: model, progress: { _ in 0.42 })
            }
            .padding(.top, UIScale.pt(PageMetrics.pinnedContentTop))
            .pageContent(compact)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DashSkin.paper(scheme == .dark))
    }
}

@MainActor final class CaptureFixture {
    static let entries: [HostExtension] = {
        let bundled = (try? HostIndex.bundled()) ?? []
        if !bundled.isEmpty { return bundled }
        return [
            HostExtension(id: "hinge", title: "Hinge", symbolName: "macwindow", category: "desk"),
            HostExtension(
                id: "keystrokeHighlight", title: "Keystrokes", symbolName: "keyboard",
                category: "desk"),
            HostExtension(
                id: "clipboard", title: "Clipboard", symbolName: "doc.on.clipboard",
                category: "desk"),
            HostExtension(
                id: "emoji", title: "Emoji", symbolName: "face.smiling", category: "desk"),
            HostExtension(
                id: "calendar", title: "Calendar", symbolName: "calendar", category: "utilities"),
            HostExtension(
                id: "notchShelf", title: "Notch Shelf",
                symbolName: "rectangle.topthird.inset.filled", category: "notch"),
        ]
    }()

    let name = "com.pulkit.edith.tests.onboarding-capture.\(UUID().uuidString)"
    let defaults: UserDefaults
    let system = HostOnboardingJourneyTests.System()
    var catalog: [String: ExtensionPackage]
    var installed = Set<String>()
    var hangRefresh = false
    var refreshFailure: String?
    var slowInstalls = Set<String>()
    var failingInstalls = Set<String>()

    init() {
        defaults = UserDefaults(suiteName: name)!
        catalog = Dictionary(
            uniqueKeysWithValues: Self.entries.enumerated().map { index, entry in
                (entry.id, Self.package(entry.id, bytes: Int64(600_000 + index * 137_000)))
            })
    }

    func remove() { defaults.removePersistentDomain(forName: name) }

    static func package(_ id: String, bytes: Int64) -> ExtensionPackage {
        ExtensionPackage(
            id: id, version: "1.4.0", hostABI: HostContract.compatibility,
            downloadURL: URL(string: "https://example.invalid/\(id).zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: bytes,
            installedBytes: bytes * 3)
    }

    func permissions() -> HostPermissions {
        let system = system
        return HostPermissions(
            environment: HostPermissionEnvironment(
                read: { system.granted },
                request: { system.requests.append($0) },
                openSettings: { _ in true }),
            defaults: defaults, recordPrompt: {}, relaunch: {})
    }

    func model() -> HostWorkflowOnboardingModel {
        let permissions = permissions()
        return HostWorkflowOnboardingModel(
            entries: Self.entries, defaults: defaults,
            environment: HostWorkflowEnvironment(
                available: { self.catalog },
                installed: { self.installed }, active: { self.installed },
                refresh: {
                    if self.hangRefresh { try await Task.sleep(for: .seconds(30)) }
                    if let failure = self.refreshFailure { throw HostWorkflowFailure(failure) }
                },
                install: { id, _ in
                    if self.slowInstalls.contains(id) { try await Task.sleep(for: .seconds(30)) }
                    if self.failingInstalls.contains(id) {
                        throw HostWorkflowFailure("The download was interrupted.")
                    }
                    self.installed.insert(id)
                }, restore: { throw HostWorkflowFailure("none") }, changed: {}),
            permissions: permissions)
    }

    func settle(_ model: HostWorkflowOnboardingModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.busy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
