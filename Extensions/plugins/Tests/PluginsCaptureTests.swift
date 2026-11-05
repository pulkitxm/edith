import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
import Vision

@testable import PluginsExtension

@Suite("PluginsCaptureTests", .serialized) @MainActor struct PluginsCaptureTests {
    enum Fixture: String, CaseIterable {
        case discovering
        case noAgents = "no-agents"
        case noInstaller = "no-installer"
        case populated
    }

    struct Variant {
        let name: String
        let size: CGSize
        let scheme: ColorScheme
        var zoom = 1.0
    }

    static let variants = [
        Variant(name: "regular-light", size: CGSize(width: 1100, height: 760), scheme: .light),
        Variant(name: "regular-dark", size: CGSize(width: 1100, height: 760), scheme: .dark),
        Variant(name: "wide-light", size: CGSize(width: 1600, height: 900), scheme: .light),
        Variant(name: "compact-light", size: CGSize(width: 640, height: 700), scheme: .light),
        Variant(name: "compact-dark", size: CGSize(width: 640, height: 700), scheme: .dark),
        Variant(
            name: "zoom-1.6", size: CGSize(width: 1100, height: 760), scheme: .light, zoom: 1.6),
    ]

    static let expectedText: [Fixture: String] = [
        .discovering: "Plugins",
        .noAgents: "No agents found",
        .noInstaller: "Installer unavailable",
        .populated: "Install",
    ]

    static let agents = [
        SkillAgent("claude-code", "Claude Code", ".claude/skills", []),
        SkillAgent("codex", "Codex", ".codex/skills", []),
    ]

    static func model(_ fixture: Fixture) async throws -> SkillsModel {
        let suite = "plugins-capture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let found = fixture == .noAgents ? [] : agents
        let installer = fixture != .noInstaller
        let model = SkillsModel(
            defaults: defaults, detectAgents: { found }, discoverInstaller: { installer })
        if fixture != .discovering { await model.discoverAgents() }
        return model
    }

    @Test(arguments: Fixture.allCases)
    func catalogStatesRenderLegiblyAtEverySize(_ fixture: Fixture) async throws {
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        let model = try await Self.model(fixture)
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            let host = NSHostingView(
                rootView: PluginsPage(model: model)
                    .environment(\.compactLayout, variant.size.width < UIScale.pt(720))
                    .environment(\.colorScheme, variant.scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                    .transaction { $0.animation = nil })
            host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: variant.size)
            let window = PluginTestWindowHost.window(contentRect: host.frame)
            defer { window.orderOut(nil) }
            window.contentView = host
            window.orderBack(nil)
            for _ in 0..<8 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(!PluginTestWindowHost.isExposedOnDesktop(window))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(model.agentsLoaded == (fixture != .discovering))
            #expect(model.agents.isEmpty == (fixture == .noAgents || fixture == .discovering))
            guard let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
            else { continue }
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent(
                    "plugins-\(fixture.rawValue)-\(variant.name).png"))
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
            let text =
                recognition.results?.compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ") ?? ""
            #expect(text.contains("Plugins"))
            #expect(
                text.contains(try #require(Self.expectedText[fixture])),
                Comment(rawValue: "\(fixture.rawValue) \(variant.name)"))
        }
        await model.shutdown()
    }

    @Test func previewAndInstallSheetsReadCleanly() async throws {
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        let skill = try #require(EdithSkillLibrary.skills.first)
        let model = try await Self.model(.populated)
        let markdown =
            "---\nname: sample\ndescription: Sample skill\n---\n\n# Sample skill\n\nUse this skill when the task needs **Edith**.\n\n## Steps\n\n1. Run `ed sample ls`.\n2. Read the result.\n\n```\ned sample ls --json\n```\n"
        let documents = SkillDocumentStore(remoteLoad: { _ in SkillDocument(markdown: markdown) })
        _ = try await documents.load(skill)
        #expect(documents.cachedDocument(for: skill)?.markdown == markdown)
        let sheets: [(String, AnyView)] = [
            ("preview", AnyView(SkillPreviewSheet(skill: skill, documents: documents))),
            ("install", AnyView(SkillInstallSheet(model: model, skill: skill))),
        ]
        for (name, sheet) in sheets {
            for (scheme, zoom, label) in [
                (ColorScheme.light, 1.0, "light"), (.dark, 1.0, "dark"), (.dark, 1.6, "zoom-dark"),
            ] {
                UIScale.apply(zoom)
                let host = NSHostingView(
                    rootView:
                        sheet
                        .environment(\.colorScheme, scheme)
                        .environment(\.controlActiveState, .key)
                        .environment(\.automaticViewActionsEnabled, false)
                        .background(DashSkin.paper(scheme == .dark))
                        .transaction { $0.animation = nil })
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                host.frame = CGRect(
                    origin: .zero,
                    size: CGSize(width: max(size.width, 320), height: max(size.height, 240)))
                let window = PluginTestWindowHost.window(contentRect: host.frame)
                defer { window.orderOut(nil) }
                window.contentView = host
                window.orderBack(nil)
                for _ in 0..<8 {
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
                #expect(!PluginTestWindowHost.isExposedOnDesktop(window))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
                else { continue }
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("plugins-sheet-\(name)-\(label).png"))
            }
        }
        await model.shutdown()
    }
}
