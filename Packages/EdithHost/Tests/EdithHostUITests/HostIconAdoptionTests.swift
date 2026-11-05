import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import Foundation
import SwiftUI
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostIconAdoptionTests {
    private struct Layout {
        let name: String
        let size: CGSize
        let zoom: Double
    }

    private static let layouts = [
        Layout(name: "regular", size: .init(width: 1100, height: 760), zoom: 1),
        Layout(name: "compact", size: .init(width: 640, height: 700), zoom: 1),
        Layout(name: "wide", size: .init(width: 1600, height: 960), zoom: 1),
        Layout(name: "zoom", size: .init(width: 1100, height: 760), zoom: 1.6),
    ]

    nonisolated private static var captureDirectory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @Test func everyBundledExtensionResolvesItsOwnIcon() throws {
        let entries = try HostIndex.bundled()
        #expect(!entries.isEmpty)
        for entry in entries { #expect(EdithIcon(rawValue: entry.id) != nil, "\(entry.id)") }
    }

    @Test(.enabled(if: captureDirectory != nil)) func onboardingStages() async throws {
        let fixture = CaptureFixture()
        defer { fixture.remove() }
        fixture.system.granted = [.calendar: true]
        let model = fixture.model()
        model.present()
        try await matrix("onboarding-welcome", fit: true) { OnboardingCapturePage(model: model) }
        model.start()
        try await matrix("onboarding-workflows", fit: true) { OnboardingCapturePage(model: model) }
        model.choose(.desk)
        try await matrix("onboarding-tools", fit: true) { OnboardingCapturePage(model: model) }
        model.choose(.custom)
        for id in ["calendar", "hinge", "keystrokeHighlight", "clipboard", "notchShelf"] {
            model.toggle(id)
        }
        model.continueFromTools()
        await model.permissions.refresh()
        try await matrix("onboarding-permissions", fit: true) {
            OnboardingCapturePage(model: model)
        }
        model.installSelection()
        await fixture.settle(model)
        try await matrix("onboarding-finished", fit: true) { OnboardingCapturePage(model: model) }
    }

    @Test(.enabled(if: captureDirectory != nil)) func extensionListAndLanding() async throws {
        let fixture = try StorefrontFixture(
            installed: ["usage": "1.1.0", "clipboard": "1.1.0", "keepAwake": "1.0.0"])
        defer { fixture.clean() }
        await fixture.marketplace.loadCachedCatalog()
        await fixture.marketplace.enable(id: "clipboard")
        try await matrix("extension-list") { MarketplacePage(marketplace: fixture.marketplace) }
        try await matrix("suite-landing") {
            HostSuiteLandingPage(
                marketplace: fixture.marketplace, destination: HostNavigationCatalog.page("desk"),
                openExtension: { _ in })
        }
    }

    @Test(.enabled(if: captureDirectory != nil)) func extensionDetail() async throws {
        let fixture = try StorefrontFixture(installed: ["usage": "1.1.0"])
        defer { fixture.clean() }
        await fixture.marketplace.loadCachedCatalog()
        for id in ["herdr", "usage", "jev"] {
            let entry = try #require(fixture.marketplace.entries.first { $0.id == id })
            try await matrix("extension-detail-\(id)", sheet: true) {
                HostExtensionReview(
                    marketplace: fixture.marketplace,
                    suites: HostSuiteSelection(
                        marketplace: fixture.marketplace, defaults: fixture.defaults),
                    entry: entry, presenter: nil, open: {}, done: {})
            }
        }
    }

    @Test(.enabled(if: captureDirectory != nil)) func firstVisitIntro() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "edith.icon-intro.\(UUID().uuidString)"))
        for id in ["herdr", "calendar"] {
            let entry = try #require(
                try HostIndex.bundled().first { $0.id == id && $0.guide != nil })
            try await matrix("intro-\(id)") {
                HostIntroducedPage(entry: entry, defaults: defaults, showsReopen: false) {
                    EmptyView()
                }
            }
        }
    }

    private func matrix<Content: View>(
        _ name: String, fit: Bool = false, sheet: Bool = false,
        @ViewBuilder content: () -> Content
    ) async throws {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.string(forKey: AppStorageKeys.General.theme)
        defer {
            defaults.set(prior, forKey: AppStorageKeys.General.theme)
        }
        for theme in [AppTheme.accent, .teal] {
            defaults.set(theme.rawValue, forKey: AppStorageKeys.General.theme)
            for _ in 0..<50 where ThemeStore.shared.theme != theme {
                try await Task.sleep(for: .milliseconds(4))
            }
            #expect(ThemeStore.shared.theme == theme)
            for layout in Self.layouts {
                for scheme in [ColorScheme.light, .dark] {
                    let label =
                        "\(name)-\(theme.rawValue)-\(layout.name)-\(scheme == .dark ? "dark" : "light")"
                    try await render(
                        label, layout: layout, scheme: scheme, fit: fit, sheet: sheet,
                        content: content())
                }
            }
        }
    }

    private func render<Content: View>(
        _ label: String, layout: Layout, scheme: ColorScheme, fit: Bool, sheet: Bool,
        content: Content
    ) async throws {
        _ = TestWindowHost.application
        let previous = UIScale.current
        UIScale.apply(layout.zoom)
        defer { UIScale.apply(previous) }
        let size =
            sheet
            ? CGSize(
                width: PresentationMetrics.width(640),
                height: PresentationMetrics.height(HostExtensionReview.aboutHeight))
            : layout.size
        let host = NSHostingView(
            rootView: AnyView(
                content
                    .frame(width: size.width)
                    .background(DashSkin.paper(scheme == .dark))
                    .environment(\.compactLayout, !sheet && size.width < UIScale.pt(720))
                    .environment(\.colorScheme, scheme)
                    .environment(\.controlActiveState, .key)
                    .environment(\.automaticViewActionsEnabled, false)
                    .transaction { $0.animation = nil }))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<6 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        if fit {
            host.frame.size.height = max(size.height, ceil(host.fittingSize.height))
            window.setContentSize(host.frame.size)
            for _ in 0..<4 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = try #require(Self.captureDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(label).png"), options: .atomic)
    }
}
