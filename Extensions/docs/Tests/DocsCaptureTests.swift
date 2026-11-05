import AppKit
import EdithDocsWorker
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
import Vision

@testable import DocsExtension

@Suite("DocsCaptureTests", .serialized) @MainActor struct DocsCaptureTests {
    enum Fixture: String, CaseIterable {
        case loading
        case failed
        case populated
        case results
        case noMatches = "no-matches"
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
        Variant(name: "compact-light", size: CGSize(width: 640, height: 700), scheme: .light),
        Variant(name: "compact-dark", size: CGSize(width: 640, height: 700), scheme: .dark),
        Variant(
            name: "zoom-1.6", size: CGSize(width: 1100, height: 760), scheme: .light, zoom: 1.6),
    ]

    static let library = DocsLibrary(sources: [
        .init(
            path: "README.md",
            markdown:
                "# Sample reference\n\nSynthetic command reference for capture tests.\n\n## Getting started\n\nRun `ed sample ls` to begin.\n\n## Next steps\n\nOpen a command from the list."
        ),
        .init(path: "sample/README.md", markdown: "# `ed sample`\n\nManage sample sessions."),
        .init(
            path: "sample/ls.md",
            markdown:
                "# `ed sample ls`\n\nLists sample sessions on this machine.\n\n## Options\n\n`--json` prints machine output.\n\n## Examples\n\n```\ned sample ls --json\n```\n"
        ),
        .init(path: "sample/stop.md", markdown: "# `ed sample stop`\n\nStops a sample session."),
        .init(path: "other/README.md", markdown: "# `ed other`\n\nSample tools."),
        .init(path: "other/run.md", markdown: "# `ed other run`\n\nRuns a sample tool."),
    ])

    static func browser(_ fixture: Fixture) async -> DocsBrowser {
        switch fixture {
        case .loading:
            return DocsBrowser(local: .none)
        case .failed:
            let browser = DocsBrowser(local: .none)
            await browser.load()
            return browser
        case .populated:
            let browser = DocsBrowser(library: library, filterDelay: .zero, local: .none)
            browser.open(DocsLocation(path: "sample/ls.md"))
            return browser
        case .results:
            let browser = DocsBrowser(library: library, filterDelay: .zero, local: .none)
            browser.question = "list sample sessions"
            await browser.submit(decider: nil)
            return browser
        case .noMatches:
            let browser = DocsBrowser(library: library, filterDelay: .zero, local: .none)
            browser.question = "zzzqqq"
            await browser.submit(decider: nil)
            return browser
        }
    }

    static func distinctColors(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                if let color = bitmap.colorAt(x: x, y: y) { colors.insert("\(color)") }
            }
        }
        return colors.count
    }

    static let expectedText: [Fixture: String] = [
        .failed: "could not be loaded",
        .populated: "Lists sample sessions",
        .results: "matched in the reference",
        .noMatches: "No command matches",
    ]

    @Test(arguments: Fixture.allCases)
    func docsStatesRenderLegiblyAtEverySize(_ fixture: Fixture) async throws {
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            let browser = await Self.browser(fixture)
            defer { browser.shutdown() }
            let view = DocsScreen(browser: browser)
                .environment(\.compactLayout, variant.size.width < UIScale.pt(720))
                .environment(\.colorScheme, variant.scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil }
            let (window, host) = ScrollHarness.host(view, size: variant.size)
            defer { window.orderOut(nil) }
            host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
            for _ in 0..<10 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(host.fittingSize.width <= variant.size.width + 1)
            #expect(Self.distinctColors(in: bitmap) > 8)
            guard let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
            else { continue }
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent(
                    "docs-\(fixture.rawValue)-\(variant.name).png"))
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
            let text =
                recognition.results?.compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ") ?? ""
            #expect(text.contains("Docs"))
            if let expected = Self.expectedText[fixture] {
                #expect(
                    text.contains(expected),
                    Comment(rawValue: "\(fixture.rawValue) \(variant.name): \(text)"))
            }
        }
    }
}
