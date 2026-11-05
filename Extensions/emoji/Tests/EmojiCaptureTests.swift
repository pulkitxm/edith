import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import EmojiExtension

@MainActor @Suite(.serialized) struct EmojiCaptureTests {
    private enum Fixture: String, CaseIterable {
        case off, empty, populated, error
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
                for (rank, character) in ["😀", "🎉", "👍", "❤️", "🔥", "😂", "🙏", "✨", "🚀", "👀", "💯", "🤔"]
                    .enumerated()
                {
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
            for variant in DeskSettingsCapture.variants {
                let bitmap = try await DeskSettingsCapture.render(
                    "emoji-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost {
                        ControlSettingsHost(presentation: model) {
                            Form { EmojiSettingsRows(presentation: model) }.deskForm()
                        }
                    }
                }
                #expect(bitmap.pixelsWide >= Int(variant.width))
                #expect(DeskSettingsCapture.distinctColors(bitmap) > 20)
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
                        NSLocalizedDescriptionKey: "The connection to the extension was interrupted."
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
