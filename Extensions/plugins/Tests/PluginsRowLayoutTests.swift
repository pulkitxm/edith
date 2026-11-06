import AppKit
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import PluginsExtension

@MainActor
@Suite("PluginsRowLayoutTests", .serialized)
struct PluginsRowLayoutTests {
    static let skill = EdithSkill(
        id: "synthetic-notes", name: "Synthetic notes",
        summary: "Keeps a running list of synthetic notes for a sample project.",
        detail: "Adds one sample command that lists and filters placeholder notes.",
        icon: .terminal)

    static let agents = [
        SkillAgent("claude-code", "Claude Code", ".claude/skills", []),
        SkillAgent("codex", "Codex", ".codex/skills", []),
    ]

    static let variants: [RenderCapture.Variant] = [ColorScheme.dark, .light].flatMap { scheme in
        [1.0, 1.6].flatMap { zoom in
            let tone = scheme == .dark ? "dark" : "light"
            let suffix = zoom == 1 ? "" : "-zoom-1.6"
            return [
                RenderCapture.Variant(
                    name: "regular-\(tone)\(suffix)", width: 900 * zoom, height: 170 * zoom,
                    zoom: zoom, scheme: scheme),
                RenderCapture.Variant(
                    name: "compact-\(tone)\(suffix)", width: 560 * zoom, height: 260 * zoom,
                    zoom: zoom, scheme: scheme),
            ]
        }
    }

    static func string(_ object: NSObject, _ selector: String) -> String? {
        let getter = NSSelectorFromString(selector)
        guard object.responds(to: getter) else { return nil }
        let value = object.perform(getter)?.takeUnretainedValue()
        return (value as? String) ?? (value as? NSAttributedString)?.string
    }

    static func frame(in root: NSObject, label: String, depth: Int = 0) -> CGRect? {
        guard depth < 64 else { return nil }
        if string(root, "accessibilityLabel") == label
            || string(root, "accessibilityTitle") == label
        {
            return (root as AnyObject).accessibilityFrame?()
        }
        for child in (root as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = frame(in: child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    @Test(arguments: [false, true])
    func previewSitsOneControlGapFromTheJoinedInstallControl(installed: Bool) async throws {
        try await RenderCapture.withAccessibility {
            for variant in Self.variants {
                var preview: CGRect?
                var install: CGRect?
                var menu: CGRect?
                let name = installed ? "plugins-row-installed" : "plugins-row"
                try await RenderCapture.render(
                    name, variant: variant,
                    inspect: { host in
                        preview = Self.frame(in: host, label: "Preview \(Self.skill.name)")
                        install = Self.frame(
                            in: host,
                            label: (installed ? "Reinstall " : "Install ") + Self.skill.name)
                        menu = Self.frame(
                            in: host, label: "Choose an agent for \(Self.skill.name)")
                    }
                ) {
                    SkillCatalogRow(
                        skill: Self.skill, agents: Self.agents, installed: installed,
                        disabled: false, preview: {}, install: { _ in }
                    )
                    .padding(UIScale.pt(PageMetrics.gutter))
                }
                let label = Comment(rawValue: variant.name)
                let previewFrame = try #require(preview, label)
                let installFrame = try #require(install, label)
                let menuFrame = try #require(menu, label)
                let gap = installFrame.minX - previewFrame.maxX
                #expect(
                    abs(gap - PageMetrics.controlSpacing * variant.zoom) < 0.51,
                    "\(variant.name) gap \(gap)")
                #expect(abs(previewFrame.midY - installFrame.midY) < 0.51, label)
                #expect(abs(installFrame.height - menuFrame.height) < 0.51, label)
                #expect(abs(installFrame.minY - menuFrame.minY) < 0.51, label)
                #expect(menuFrame.minX - installFrame.maxX <= 1.01, label)
                #expect(menuFrame.minX >= installFrame.maxX, label)
                #expect(abs(menuFrame.width - menuFrame.height) < 0.51, label)
            }
        }
    }
}
