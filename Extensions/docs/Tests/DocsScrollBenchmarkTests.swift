import AppKit
import EdithDocsWorker
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import DocsExtension

@Suite(.serialized) @MainActor struct DocsScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingNavigatorAndLongDocument() async throws {
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for scenario in Scenario.allCases where only == nil || only == scenario.rawValue {
            let timing = await Self.measure(
                scenario, groups: 40, pagesPerGroup: 12, lines: 5000, frames: frames)
            print(
                "docs-scroll \(scenario.rawValue): \(timing) reach=\(Int(timing.offsets.max() ?? 0)) slowAt=\(timing.slowOffsets)"
            )
        }
    }

    @Test func scrollingStaysSmoothWithManyPagesAndALongDocument() async throws {
        for scenario in Scenario.allCases {
            let timing = await Self.measure(
                scenario, groups: 10, pagesPerGroup: 10, lines: 800, frames: 60)
            print("docs-regression \(scenario.rawValue): \(timing)")
            #expect(timing.frames.count == 60)
            #expect(timing.worst < 100)
            #expect(timing.median < 12)
        }
    }

    enum Scenario: String, CaseIterable {
        case navigator
        case document
    }

    static func measure(
        _ scenario: Scenario, groups: Int, pagesPerGroup: Int, lines: Int, frames: Int
    ) async -> ScrollTiming {
        let suite = "docs-scroll-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = DocsLibrary(
            sources: sources(groups: groups, pagesPerGroup: pagesPerGroup, lines: lines))
        let browser = DocsBrowser(library: library, defaults: defaults)
        switch scenario {
        case .navigator:
            browser.expandedGroups = Set(library.groups.map(\.id))
        case .document:
            browser.open(.init(path: "big/long.md"), reveal: false)
        }
        let (window, host) = ScrollHarness.host(
            ExtensionPageHost { DocsScreen(browser: browser) }
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1280, height: 860))
        await ScrollHarness.settle(host, for: .seconds(1))
        let timing = await ScrollHarness.scroll(host, frames: frames)
        await ScrollHarness.settle(host)
        window.orderOut(nil)
        window.contentView = nil
        browser.shutdown()
        return timing
    }

    static func sources(groups: Int, pagesPerGroup: Int, lines: Int) -> [DocsSource] {
        var result = [
            DocsSource(path: "README.md", markdown: "# Reference\n\nSynthetic command reference.")
        ]
        for group in 0..<groups {
            result.append(
                DocsSource(
                    path: "group\(group)/README.md",
                    markdown: "# `ed group\(group)`\n\nSynthetic group \(group)."))
            for page in 0..<pagesPerGroup {
                result.append(
                    DocsSource(
                        path: "group\(group)/command\(page).md",
                        markdown:
                            "# `ed group\(group) command\(page)`\n\nRuns synthetic command \(page).\n\n## Options\n\n`--json`"
                    ))
            }
        }
        result.append(
            DocsSource(path: "big/README.md", markdown: "# `ed big`\n\nA long synthetic page."))
        result.append(DocsSource(path: "big/long.md", markdown: longDocument(lines: lines)))
        return result
    }

    static func longDocument(lines: Int) -> String {
        var output = ["# `ed big long`", ""]
        var section = 0
        while output.count < lines {
            section += 1
            output.append(contentsOf: [
                "## Section \(section)", "",
                "A synthetic paragraph with **bold text**, `inline code`, and a [link](https://example.com/\(section)) that wraps across a line or two so layout has real work to do in section \(section).",
                "",
                "- first item of section \(section)", "- second item with `code`",
                "- third item with **emphasis**", "- fourth item", "",
                "```bash", "ed big run --section \(section)", "ed big status --json",
                "echo done", "```", "",
                "| Name | Value | Notes |", "| --- | --- | --- |",
                "| alpha | \(section) | first row |", "| beta | \(section + 1) | second row |",
                "",
                "### Details \(section)", "", "Closing paragraph for section \(section).", "",
            ])
        }
        return output.joined(separator: "\n")
    }
}
