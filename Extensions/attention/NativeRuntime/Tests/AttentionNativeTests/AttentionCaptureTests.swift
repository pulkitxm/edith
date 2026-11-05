import AppKit
import Foundation
import SwiftUI
import Testing
import EdithExtensionUI

@testable import AttentionNative

@MainActor
@Suite(.serialized)
struct AttentionCaptureTests {
    private static let apps: [(name: String, bundle: String, title: String)] = [
        ("Fixture Editor", "com.example.fixture.editor", "Sample workspace"),
        ("Fixture Terminal", "com.example.fixture.terminal", "build and test"),
        ("Fixture Notes", "com.example.fixture.notes", "Meeting notes"),
        ("Fixture Chat", "com.example.fixture.chat", "Team room"),
        ("Fixture Mail", "com.example.fixture.mail", "Inbox"),
    ]

    private func repository() throws -> (AttentionRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-capture-\(UUID().uuidString)")
        return (AttentionRepository(root: root), root)
    }

    private func populated(_ repository: AttentionRepository) throws {
        try repository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
        let now = Date()
        for index in 0..<60 {
            let app = Self.apps[(index * 7 + index / 3) % Self.apps.count]
            try repository.append(
                AttentionEvent(
                    id: "fixture-\(index)",
                    startedAt: now.addingTimeInterval(TimeInterval(-(index + 1) * 300)),
                    duration: TimeInterval(120 + index % 5 * 30), source: .application,
                    appName: app.name, bundleID: app.bundle, windowTitle: app.title))
        }
        for index in 0..<16 {
            try repository.append(
                AttentionEvent(
                    id: "fixture-site-\(index)",
                    startedAt: now.addingTimeInterval(TimeInterval(-(index + 1) * 610)),
                    duration: 180, source: .browser, appName: "Fixture Browser",
                    bundleID: "com.example.fixture.browser",
                    url: "https://docs.example.com/page/\(index)", domain: "docs.example.com"))
        }
    }

    @Test func everySectionRendersWithSyntheticActivity() async throws {
        let (repository, root) = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try populated(repository)
        let model = AttentionPageModel(repository: repository)
        model.reload()
        await model.waitForReload()
        #expect(model.loaded && model.hasActivity)
        for section in AttentionPageSection.allCases {
            model.section = section
            model.reload()
            await model.waitForReload()
            let variants =
                section == .overview
                ? AttentionRenderCapture.variants
                : [AttentionRenderCapture.variants[0], AttentionRenderCapture.variants[3]]
            for variant in variants {
                let bitmap = try await AttentionRenderCapture.render(
                    "attention-\(section.rawValue)", variant: variant
                ) { AttentionPage(model: model) }
                #expect(AttentionRenderCapture.distinctColors(bitmap) > 3)
            }
        }
        await model.shutdown()
    }

    @Test func firstRunCollectingLoadingAndErrorStatesRender() async throws {
        for variant in AttentionRenderCapture.variants {
            let (setupRepository, setupRoot) = try repository()
            defer { try? FileManager.default.removeItem(at: setupRoot) }
            let setup = AttentionPageModel(repository: setupRepository)
            setup.reload()
            await setup.waitForReload()
            #expect(setup.needsSetup)
            try await AttentionRenderCapture.render("attention-setup", variant: variant) {
                AttentionPage(model: setup)
            }
            await setup.shutdown()

            let (idleRepository, idleRoot) = try repository()
            defer { try? FileManager.default.removeItem(at: idleRoot) }
            try idleRepository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
            let collecting = AttentionPageModel(repository: idleRepository)
            collecting.reload()
            await collecting.waitForReload()
            #expect(!collecting.hasActivity)
            try await AttentionRenderCapture.render("attention-collecting", variant: variant) {
                AttentionPage(model: collecting)
            }
            await collecting.shutdown()

            let (loadingRepository, loadingRoot) = try repository()
            defer { try? FileManager.default.removeItem(at: loadingRoot) }
            let loading = AttentionPageModel(repository: loadingRepository)
            #expect(!loading.loaded)
            try await AttentionRenderCapture.render("attention-loading", variant: variant) {
                AttentionPage(model: loading)
            }

            let (failingRepository, failingRoot) = try repository()
            defer { try? FileManager.default.removeItem(at: failingRoot) }
            let failing = AttentionPageModel(repository: failingRepository)
            let request = failing.loading.begin()
            failing.loading.fail(request, message: "The activity store could not be opened.")
            #expect(failing.loading.state == .error)
            try await AttentionRenderCapture.render("attention-error", variant: variant) {
                AttentionPage(model: failing)
            }
        }
    }
}
