import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import EmojiExtension

@MainActor @Suite(.serialized) struct EmojiCaptureTests {
    private let fixture = EmojiDefaultsFixture()

    private static let wide = RenderCapture.Variant(
        name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light)

    private enum Fixture: String, CaseIterable {
        case off, empty, populated, error
    }

    @Test func panelKeepsItsEdgesAndCentersTheNoMatchState() async throws {
        for (name, query) in [("catalog", ""), ("nomatch", "zzzzzz")] {
            for scheme in [ColorScheme.light, .dark] {
                let store = EmojiStore(
                    defaults: fixture.defaults, writePasteboard: fixture.writePasteboard,
                    catalog: .shared, typeCharacter: { _ in true })
                let model = EmojiPanelModel(
                    catalog: store.catalog, frequent: store.frequent, search: store.search)
                let task = Task {
                    try await Task.sleep(for: .milliseconds(120))
                    model.setQuery(query)
                }
                try await RenderCapture.render(
                    "emoji-panel-\(name)",
                    variant: .init(
                        name: scheme == .dark ? "dark" : "light", width: 520,
                        height: EmojiPanel.height + 48, zoom: 1, scheme: scheme),
                    settle: .milliseconds(900)
                ) {
                    EmojiPanelView(store: store, model: model, onDismiss: {})
                        .background(.regularMaterial)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                try await task.value
            }
        }
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        let defaults = SharedDefaults.store
        let keys = ControlPresentationContract.readable
        let stored = ControlPresentationContract.values(from: defaults, keys: keys)
        defer {
            for key in keys { defaults.removeObject(forKey: key) }
            for (key, value) in stored { defaults.set(value, forKey: key) }
        }
        for fixture in Fixture.allCases {
            for key in keys { defaults.removeObject(forKey: key) }
            if fixture == .populated || fixture == .off {
                var ledger = EmojiUsageLedger()
                let now = Date()
                for (rank, character) in [
                    "😀", "🎉", "👍", "❤️", "🔥", "😂", "🙏", "✨", "🚀", "👀", "💯", "🤔",
                ]
                .enumerated() {
                    for _ in 0..<(12 - rank) { ledger.record(character, at: now) }
                }
                ledger.save(to: defaults, key: AppStorageKeys.Emoji.usage)
            }
            let model = Self.presentation(fixture, defaults: defaults)
            defer { model.stop() }
            if fixture != .off { await model.refresh() }
            if fixture == .error {
                model.perform("pick")
                for _ in 0..<200 where model.error == nil { await Task.yield() }
            }
            #expect(model.active == (fixture != .off))
            #expect((model.error != nil) == (fixture == .error))
            #expect(
                EmojiCatalogSummary.frequent(store: defaults).isEmpty
                    == (fixture == .empty || fixture == .error))
            for variant in RenderCapture.variants + RenderCapture.sheetVariants + [Self.wide] {
                let rendered = try await RenderCapture.render(
                    "emoji-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost {
                        ControlSettingsHost(presentation: model) {
                            Form { EmojiSettingsRows(presentation: model) }.settingsForm()
                        }
                    }
                }
                #expect(rendered.bitmap.pixelsWide >= Int(variant.width))
                #expect(RenderCapture.distinctColors(rendered.bitmap) > 20)
            }
        }
    }

    private static func presentation(_ fixture: Fixture, defaults: UserDefaults)
        -> ControlPresentation
    {
        switch fixture {
        case .off:
            return ControlPresentation(client: nil, defaults: defaults)
        case .error:
            return ControlPresentation(client: nil, defaults: defaults) { _, _ in
                throw NSError(
                    domain: "EmojiCapture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The connection to the extension was interrupted."
                    ])
            }
        case .empty, .populated:
            return ControlPresentation(client: nil, defaults: defaults) { operation, _ in
                guard operation == "emoji.ui.read" else { return Data() }
                return try await MainActor.run {
                    try ControlPresentationContract.snapshot(
                        defaults: defaults, state: ControlPresentationState())
                }
            }
        }
    }
}
