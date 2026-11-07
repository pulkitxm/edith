import EdithExtensionCore
import AppKit
import QuartzCore
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import AttentionNative

@Suite(.serialized) @MainActor struct AttentionScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil
    static let medianBudget = ProcessInfo.processInfo.environment["CI"] == nil ? 12.0 : 1000.0 / 60

    @Test(.enabled(if: enabled)) func scrollingEverySectionWithSyntheticHistory() async throws {
        let fixture = try AttentionSyntheticHistory.make(days: 7, eventsPerDay: 420)
        defer { fixture.cleanup() }
        let requests = AttentionRequestCounter()
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for (section, preset) in [
            (AttentionPageSection.overview, DateFilterPreset.today),
            (.overview, .last7), (.timeline, .last7), (.breakdown, .last7), (.focus, .last7),
            (.agents, .last7),
        ] where only == nil || only == "\(section.rawValue)-\(preset.rawValue)" {
            requests.reset()
            let client = fixture.client(counter: requests)
            let model = AttentionPageModel(repository: fixture.repository, uiClient: client)
            model.section = section
            model.select(.preset(preset))
            model.reload()
            await model.waitForReload()
            let realizeStart = CACurrentMediaTime()
            let (window, host) = AttentionScrollHarness.host(
                AttentionPage(model: model)
                    .environment(\.compactLayout, false)
                    .environment(\.colorScheme, .dark),
                size: CGSize(width: 1280, height: 860))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let realizeMs = (CACurrentMediaTime() - realizeStart) * 1000
            await AttentionScrollHarness.settle(host, for: .seconds(1))
            let before = requests.icons
            let timing = await AttentionScrollHarness.scroll(host, frames: frames)
            await AttentionScrollHarness.settle(host)
            print(
                "attention-scroll \(section.rawValue) \(preset.rawValue): realize=\(Int(realizeMs))ms \(timing) iconRequestsDuringScroll=\(requests.icons - before) slowAt=\(timing.slowOffsets)"
            )
            window.orderOut(nil)
            window.contentView = nil
            await model.shutdown()
        }
    }
}

extension AttentionScrollBenchmarkTests {
    @Test func overviewScrollDoesNotRealizePanelsMidScroll() async throws {
        let fixture = try AttentionSyntheticHistory.make(days: 7, eventsPerDay: 420)
        defer { fixture.cleanup() }
        let model = AttentionPageModel(
            repository: fixture.repository,
            uiClient: fixture.client(counter: AttentionRequestCounter()))
        model.section = .overview
        model.select(.preset(.last7))
        model.reload()
        await model.waitForReload()
        let (window, host) = AttentionScrollHarness.host(
            AttentionPage(model: model)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1280, height: 860))
        await AttentionScrollHarness.settle(host, for: .seconds(1))
        let timing = await AttentionScrollHarness.scroll(host, frames: 240)
        window.orderOut(nil)
        window.contentView = nil
        await model.shutdown()
        #expect(timing.frames.count == 240)
        #expect(timing.frames.filter { $0 > 60 }.count <= 1, "\(timing)")
        #expect(timing.median < Self.medianBudget, "\(timing)")
    }

    @Test(.enabled(if: enabled)) func expandedActivityBrowser() async throws {
        let fixture = try AttentionSyntheticHistory.make(
            days: 7, eventsPerDay: 420, appCount: 500, siteCount: 400)
        defer { fixture.cleanup() }
        let counter = AttentionRequestCounter()
        let model = AttentionPageModel(
            repository: fixture.repository, uiClient: fixture.client(counter: counter))
        model.section = .overview
        model.select(.preset(.last7))
        model.reload()
        await model.waitForReload()
        let (window, host) = AttentionScrollHarness.host(
            ScrollView {
                AttentionEntitiesPanel(model: model, limit: 600).padding(24)
            }
            .environment(\.compactLayout, false)
            .environment(\.colorScheme, .dark),
            size: CGSize(width: 1280, height: 860))
        await AttentionScrollHarness.settle(host, for: .seconds(1))
        let timing = await AttentionScrollHarness.scroll(host, frames: 300)
        print(
            "attention-scroll activity-browser entities=\(model.summary.entities.count) shown=600: \(timing) slowAt=\(timing.slowOffsets)"
        )
        window.orderOut(nil)
        window.contentView = nil
        await model.shutdown()
    }

    @Test(.enabled(if: enabled)) func realizingEachOverviewPanel() async throws {
        let fixture = try AttentionSyntheticHistory.make(days: 7, eventsPerDay: 420)
        defer { fixture.cleanup() }
        let client = fixture.client(counter: AttentionRequestCounter())
        let model = AttentionPageModel(repository: fixture.repository, uiClient: client)
        model.section = .overview
        model.select(.preset(.last7))
        model.reload()
        await model.waitForReload()
        let panels: [(String, AnyView)] = [
            ("headline", AnyView(AttentionHeadline(model: model))),
            ("allocation", AnyView(AttentionAllocationPanel(model: model))),
            ("entities", AnyView(AttentionEntitiesPanel(model: model, limit: 12))),
            ("day", AnyView(AttentionDayPanel(model: model))),
            ("categories", AnyView(AttentionCategoryPanel(model: model))),
            ("hours", AnyView(AttentionHoursPanel(model: model))),
            ("triage", AnyView(AttentionTriagePanel(model: model))),
            ("edith", AnyView(AttentionEdithPanel(model: model))),
            ("switching", AnyView(AttentionSwitchingPanel(model: model))),
            ("agents", AnyView(AttentionAgentsSummaryPanel(model: model))),
            ("listening", AnyView(AttentionListeningPanel(model: model))),
        ]
        for (name, panel) in panels + panels {
            let start = CACurrentMediaTime()
            let (window, host) = AttentionScrollHarness.host(
                panel.environment(\.compactLayout, false).environment(\.colorScheme, .dark),
                size: CGSize(width: 1100, height: 600))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let first = (CACurrentMediaTime() - start) * 1000
            print(String(format: "attention-panel %@ firstRealize=%.1fms", name, first))
            window.orderOut(nil)
            window.contentView = nil
        }
        await model.shutdown()
    }
}

@MainActor
final class AttentionRequestCounter {
    var icons = 0
    var summaries = 0
    func reset() { icons = 0; summaries = 0 }
}

struct AttentionSyntheticHistory {
    let root: URL
    let repository: AttentionRepository

    static func make(days: Int, eventsPerDay: Int, appCount: Int = 48, siteCount: Int = 32) throws
        -> AttentionSyntheticHistory
    {
        let applications = (0..<appCount).map { ("Sample App \($0)", "test.sample.app\($0)") }
        let sites = (0..<siteCount).map { "site\($0).example.com" }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-attention-scroll-\(UUID().uuidString)")
        let repository = AttentionRepository(root: root)
        var settings = repository.loadSettings()
        settings.isEnabled = true
        settings.trackingEnabled = true
        try repository.saveSettings(settings)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = Date()
        for day in 0..<days {
            let start = calendar.date(byAdding: .day, value: -day, to: today)!
                .addingTimeInterval(6 * 3_600)
            for index in 0..<eventsPerDay {
                let at = start.addingTimeInterval(Double(index) * 75)
                guard at.addingTimeInterval(70) < now else { break }
                let event: AttentionEvent
                if index.isMultiple(of: 3) {
                    let site = sites[(index / 3 + day) % sites.count]
                    event = AttentionEvent(
                        startedAt: at, duration: 70, source: .browser, appName: "Browser",
                        bundleID: "test.sample.browser", windowTitle: "Article \(index) on \(site)",
                        url: "https://\(site)/read/\(index)", domain: site,
                        faviconURL: "https://\(site)/favicon.ico")
                } else {
                    let app = applications[(index + day * 7) % applications.count]
                    event = AttentionEvent(
                        startedAt: at, duration: 70, source: .application, appName: app.0,
                        bundleID: app.1, windowTitle: "Document \(index % 97)")
                }
                try repository.append(event)
            }
        }
        return AttentionSyntheticHistory(root: root, repository: repository)
    }

    @MainActor
    func client(counter: AttentionRequestCounter) -> AttentionUIClient {
        let repository = repository
        let icon = Self.largeIconPNG
        let favicon = Self.faviconPNG
        return AttentionUIClient(send: { operation, payload in
            switch operation {
            case "attention.ui.summary":
                counter.summaries += 1
                let request = try AttentionPayload.decode(
                    AttentionSummaryRequest.self, from: payload)
                let snapshot = await Task.detached {
                    AttentionPageSnapshot(request: request, repository: repository)
                        .trimmed(to: request.parts)
                }.value
                return try AttentionPayload.encode(snapshot)
            case "attention.ui.status":
                return try AttentionPayload.encode(AttentionUIStatus())
            case "attention.ui.application.icon":
                counter.icons += 1
                try await Task.sleep(for: .milliseconds(2))
                return try AttentionPayload.encode(Optional(icon))
            case AgentFaviconClient.operation:
                counter.icons += 1
                try await Task.sleep(for: .milliseconds(2))
                return try AttentionPayload.encode(Optional(favicon))
            default:
                return Data("{}".utf8)
            }
        })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static let largeIconPNG: Data = png(side: 1024)
    static let faviconPNG: Data = png(side: 64)

    static func png(side: Int) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side), angle: 45)
        NSColor.white.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: side / 4, y: side / 4, width: side / 2, height: side / 2)
        ).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }
}
