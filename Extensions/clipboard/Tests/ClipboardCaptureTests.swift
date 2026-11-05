import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import ClipboardExtension

@MainActor @Suite(.serialized) struct ClipboardCaptureTests {
    private enum Fixture: String, CaseIterable {
        case loading, error, firstRun, populated, off
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        for fixture in Fixture.allCases {
            let presentation = ClipboardPresentation(
                send: Self.engine(fixture), available: fixture != .off)
            if fixture != .loading { await presentation.refresh() }
            #expect(presentation.preferencesLoad.hasContent == ![.loading, .error].contains(fixture))
            #expect((presentation.preferencesLoad.errorMessage != nil) == (fixture == .error))
            for variant in DeskSettingsCapture.variants + [
                .init(name: "full-light", width: 640, height: 2200, zoom: 1, scheme: .light)
            ] {
                let bitmap = try await DeskSettingsCapture.render(
                    "clipboard-\(fixture.rawValue)", variant: variant, settle: .milliseconds(400)
                ) {
                    ExtensionPageHost {
                        ClipboardPage(
                            client: presentation.client, history: presentation.history,
                            openPalette: {}, presentation: presentation)
                    }
                }
                #expect(bitmap.pixelsWide >= Int(variant.width))
                #expect(DeskSettingsCapture.distinctColors(bitmap) > 4)
            }
            await presentation.stopAndWait()
        }
    }

    private static func engine(_ fixture: Fixture) -> @MainActor (String, Data) async throws -> Data {
        { operation, _ in
            switch fixture {
            case .loading:
                try await Task.sleep(for: .seconds(600))
                return Data()
            case .error:
                throw NSError(
                    domain: "ClipboardCapture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The connection to the extension was interrupted."
                    ])
            case .firstRun, .populated, .off:
                if operation == "clipboard.ui.preferences" {
                    return try ClipboardMessage.encode(ClipboardPreferences())
                }
                if operation == "clipboard.ui.snapshot" {
                    let entries = fixture == .populated ? Self.entries : []
                    return try ClipboardMessage.encode(
                        ClipboardSnapshot(entries: entries, revision: "fixture", total: entries.count))
                }
                return Data("{}".utf8)
            }
        }
    }

    private static let entries: [ClipboardEntry] = [
        ("https://docs.example.com/getting-started", "Safari", 40.0),
        ("Meeting moved to 3:30, same room.", "Messages", 300),
        ("#1A73E8", "Figma", 1_800),
        ("let greeting = \"Hello, world\"", "Xcode", 7_200),
        ("Order number 48213-AX", "Mail", 86_400),
    ].map { preview, app, age in
        ClipboardEntry(
            sha256: UUID().uuidString, types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: app, sourceBundleID: nil, createdAt: Date().addingTimeInterval(-age),
            size: preview.utf8.count, preview: preview)
    }
}
