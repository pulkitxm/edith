import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import BifrostExtension

@MainActor @Suite(.serialized) struct BifrostCaptureTests {
    private enum Fixture: String, CaseIterable {
        case loading, error, firstRun, populated, off
    }

    @Test func settingsRenderEveryStateAtEverySize() async throws {
        let defaults = SharedDefaults.store
        let keys = BifrostUIContext.keys + [AppStorageKeys.Bifrost.usage]
        let stored = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in stored {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for fixture in Fixture.allCases {
            for key in keys { defaults.removeObject(forKey: key) }
            let context = BifrostUIContext(invoke: Self.engine(fixture))
            BifrostUIContext.current = context
            defer {
                context.stop()
                BifrostUIContext.current = nil
            }
            if fixture != .loading { await context.load() }
            #expect(context.loaded == [.firstRun, .populated, .off].contains(fixture))
            #expect((context.error != nil) == (fixture == .error))
            for variant in DeskSettingsCapture.variants + [
                .init(name: "full-light", width: 640, height: 2400, zoom: 1, scheme: .light)
            ] {
                let bitmap = try await DeskSettingsCapture.render(
                    "launcher-\(fixture.rawValue)", variant: variant
                ) {
                    ExtensionPageHost { BifrostSettings(context: context) }
                        .environment(\.automaticViewActionsEnabled, false)
                }
                #expect(bitmap.pixelsWide >= Int(variant.width))
                #expect(DeskSettingsCapture.distinctColors(bitmap) > 4)
            }
        }
    }

    @Test func aSuccessfulLoadClearsAnEarlierFailure() async throws {
        var failing = true
        let context = BifrostUIContext(invoke: { operation, _ in
            if failing { throw CocoaError(.featureUnsupported) }
            guard operation == "bifrost.ui.settings" else { return Data("{}".utf8) }
            return try JSONEncoder().encode(BifrostUISettings(values: [:], index: nil))
        })
        defer { context.stop() }
        await context.load()
        #expect(context.error != nil)
        #expect(!context.loaded)
        failing = false
        await context.load()
        #expect(context.loaded)
        #expect(context.error == nil)
    }

    private static func engine(_ fixture: Fixture) -> (String, Data) async throws -> Data {
        { operation, _ in
            switch fixture {
            case .loading:
                try await Task.sleep(for: .seconds(600))
                return Data()
            case .error:
                throw NSError(
                    domain: "BifrostCapture", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The connection to the extension was interrupted."
                    ])
            case .firstRun, .populated, .off:
                guard operation == "bifrost.ui.settings" else { return Data("{}".utf8) }
                return try JSONEncoder().encode(settings(fixture))
            }
        }
    }

    private static func settings(_ fixture: Fixture) -> BifrostUISettings {
        var values = [AppStorageKeys.Bifrost.enabled: fixture == .off ? "false" : "true"]
        guard fixture != .firstRun else { return BifrostUISettings(values: values, index: nil) }
        values[AppStorageKeys.Bifrost.quicklinks] = BifrostLibrary.encode([
            BifrostQuicklink(
                name: "Search the docs", target: "https://docs.example.com/search?q={query}",
                keyword: "docs")
        ])
        values[AppStorageKeys.Bifrost.snippets] = BifrostLibrary.encode([
            BifrostSnippet(name: "Meeting link", content: "https://meet.example.com/standup", keyword: "meet")
        ])
        let index = BifrostIndex(
            generatedAt: Date(),
            applications: ["Fixture Notes", "Fixture Mail", "Fixture Music", "Fixture Maps"].map {
                BifrostApplication(name: $0, path: "/synthetic/\($0).app")
            })
        return BifrostUISettings(values: values, index: index)
    }
}
