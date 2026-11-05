import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import BifrostExtension

@MainActor @Suite(.serialized) struct BifrostPanelCaptureTests {
    private static let variants = [
        RenderCapture.Variant(name: "light", width: 900, height: 620, zoom: 1, scheme: .light),
        RenderCapture.Variant(name: "dark", width: 900, height: 620, zoom: 1, scheme: .dark),
    ]

    private func makeStore() throws -> BifrostStore {
        let suite = "BifrostPanelCaptureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bifrost-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = BifrostIndexStore(location: directory.appendingPathComponent("index.json"))
        index.save(
            BifrostIndex(
                generatedAt: Date(),
                applications: ["Fixture Notes", "Fixture Mail", "Fixture Music", "Fixture Maps"].map
                {
                    BifrostApplication(name: $0, path: "/synthetic/\($0).app")
                }))
        return BifrostStore(
            store: defaults, indexStore: index, startServices: false, scan: { [] },
            open: { _ in true }, copy: { _ in })
    }

    private func panel(_ store: BifrostStore, scheme: ColorScheme) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(white: 0.16), Color(white: 0.3)]
                    : [Color(white: 0.92), Color(white: 0.72)],
                startPoint: .top, endPoint: .bottom)
            BifrostPanelView(store: store, onDismiss: {}).themedControls().padding(.top, 32)
        }
    }

    private func brightPixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        var count = 0
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent + color.greenComponent + color.blueComponent > 2.1 {
                    count += 1
                }
            }
        }
        return count
    }

    private func type(_ query: String) {
        NotificationCenter.default.post(
            name: BifrostPanel.willShow, object: nil, userInfo: [BifrostPanel.prefillKey: query])
    }

    @Test func barRendersEveryLauncherStateInBothAppearances() async throws {
        let store = try makeStore()
        defer { store.shutdown() }
        #expect(!store.results(for: "fixture").isEmpty)
        #expect(store.results(for: "zzzzzz").isEmpty)
        #expect(store.results(for: "12 * 8").contains { $0.answer != nil })
        for (name, query) in [
            ("empty", ""), ("results", "fixture"), ("answer", "12 * 8"), ("nothing", "zzzzzz"),
        ] {
            for variant in Self.variants {
                let task = Task {
                    try await Task.sleep(for: .milliseconds(120))
                    type(query)
                }
                let rendered = try await RenderCapture.render(
                    "launcher-bar-\(name)", variant: variant
                ) { panel(store, scheme: variant.scheme) }
                try await task.value
                #expect(RenderCapture.distinctColors(rendered.bitmap) > 4)
                if name == "results" {
                    let firstTitle = CGRect(x: 120, y: 128, width: 96, height: 28)
                    #expect(brightPixels(rendered.bitmap, in: firstTitle) > 40)
                }
                if name == "nothing" {
                    let message = CGRect(x: 380, y: 100, width: 140, height: 24)
                    #expect(brightPixels(rendered.bitmap, in: message) > 40)
                }
            }
        }
    }

    @Test func resultListAndDetailPaneShareTheirInsets() async throws {
        let detail = BifrostDetail(
            title: "Information",
            rows: [
                BifrostDetailRow("Source", "Fixture Notes"),
                BifrostDetailRow("Copied", "5 minutes ago"),
                BifrostDetailRow("Size", "48 bytes"),
            ],
            text: "Meeting moved to 3:30, same room.")
        let results = ["Meeting moved to 3:30", "https://docs.example.com", "#1A73E8"].map {
            BifrostResult(
                id: $0, kind: .clip, title: $0, subtitle: "Fixture Notes",
                icon: .clipboard, action: .copy(text: $0), score: 1, detail: detail)
        }
        for variant in Self.variants {
            try await RenderCapture.render("launcher-split", variant: variant) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        BifrostSectionHeader(title: "TODAY")
                        ForEach(results) { result in
                            BifrostResultRow(
                                result: result, isSelected: result.id == results[0].id,
                                shortcut: nil, showsAccessory: false)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(
                        width: BifrostPanelMetrics.width * (1 - BifrostPanelMetrics.detailFraction))
                    Divider().opacity(0.25)
                    BifrostDetailPane(detail: detail).frame(maxWidth: .infinity)
                }
                .frame(
                    width: BifrostPanelMetrics.width, height: BifrostPanelMetrics.modeHeight
                )
                .background(BifrostPanelMetrics.scrim)
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @Test func historyModeShowsItsOwnEmptyDetail() async throws {
        let store = try makeStore()
        defer { store.shutdown() }
        store.enter(.clipboard)
        #expect(store.mode == .clipboard)
        for variant in Self.variants {
            let rendered = try await RenderCapture.render("launcher-history", variant: variant) {
                panel(store, scheme: variant.scheme)
            }
            #expect(RenderCapture.distinctColors(rendered.bitmap) > 4)
        }
    }
}
