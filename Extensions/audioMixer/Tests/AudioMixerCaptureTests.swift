import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@testable import AudioMixerExtension

@available(macOS 14.4, *) @MainActor @Observable
private final class FixtureMixer: AudioMixerPresenting {
    var apps: [MixerApp]
    var errorMessage: String?
    var loaded: Bool
    private(set) var changes: [(String, Float)] = []

    init(apps: [MixerApp] = [], errorMessage: String? = nil, loaded: Bool = true) {
        self.apps = apps
        self.errorMessage = errorMessage
        self.loaded = loaded
    }

    func setVolume(_ app: MixerApp, _ volume: Float) {
        changes.append((app.name, volume))
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].volume = volume }
    }
    func retry() {}
    func viewAppeared() {}
    func viewDisappeared() {}

    static let playing: [MixerApp] = [
        .init(
            objectID: 1, pid: 4001, bundleID: "synthetic.music", name: "Tunes", icon: nil,
            volume: 0.8),
        .init(
            objectID: 2, pid: 4002, bundleID: "synthetic.browser", name: "Web Browser", icon: nil,
            volume: 0.35),
        .init(
            objectID: 3, pid: 4003, bundleID: "synthetic.calls",
            name: "Video Calls With A Long Name", icon: nil, volume: 1),
        .init(
            objectID: 4, pid: 4004, bundleID: "synthetic.game", name: "Game", icon: nil, volume: 0),
    ]
}

@MainActor @Suite(.serialized) struct AudioMixerCaptureTests {
    @Test func pageCoversLoadingEmptyPopulatedAndError() async throws {
        guard #available(macOS 14.4, *) else { return }
        let states: [(String, FixtureMixer, Bool)] = [
            ("loading", FixtureMixer(loaded: false), false),
            ("empty", FixtureMixer(), true),
            ("populated", FixtureMixer(apps: FixtureMixer.playing), true),
            (
                "error",
                FixtureMixer(
                    apps: FixtureMixer.playing,
                    errorMessage:
                        "Could not change Web Browser's volume. Allow audio access and try again."),
                false
            ),
        ]
        for (name, mixer, zoomed) in states {
            for variant in SurfaceCapture.variants where zoomed || variant.zoom == 1 {
                try await SurfaceCapture.render("mixer-page-\(name)", variant: variant) {
                    ExtensionPageHost { AudioMixerPage(engine: mixer) }
                }
            }
        }
        #expect(states.allSatisfy { $0.1.changes.isEmpty })
    }

    @Test func notchTabCoversEmptyPopulatedAndError() async throws {
        guard #available(macOS 14.4, *) else { return }
        let notch = SurfaceCapture.Variant(
            name: "notch", size: CGSize(width: 560, height: 220), scheme: .dark, zoom: 1)
        for (name, mixer) in [
            ("loading", FixtureMixer(loaded: false)), ("empty", FixtureMixer()),
            ("populated", FixtureMixer(apps: FixtureMixer.playing)),
            (
                "error",
                FixtureMixer(
                    apps: Array(FixtureMixer.playing.prefix(1)),
                    errorMessage: "Could not change Tunes's volume.")
            ),
        ] {
            try await SurfaceCapture.render("mixer-notch-\(name)", variant: notch) {
                ExtensionPageHost { AudioMixerView(engine: mixer, notch: true).background(.black) }
            }
        }
    }

    @Test func settingsExplainWhereTheMixerLives() async throws {
        for variant in SurfaceCapture.variants {
            try await SurfaceCapture.render("mixer-settings", variant: variant) {
                ExtensionPageHost { AudioMixerSettingsPage() }
            }
        }
    }
}
