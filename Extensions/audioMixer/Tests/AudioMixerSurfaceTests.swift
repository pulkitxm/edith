import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing
@testable import AudioMixerExtension

private final class SurfaceTapProbe: AudioMixerTapControlling {
    var gains: [Float] = []
    var destroyed = 0
    func setGain(_ value: Float) { gains.append(value) }
    func destroy() { destroyed += 1 }
}

@Suite(.serialized) @MainActor struct AudioMixerSurfaceTests {
    @Test func sliderAndMuteUseCurrentProcessIdentity() async throws {
        guard #available(macOS 14.4, *) else { return }
        let tap = SurfaceTapProbe()
        var apps = [app(41, pid: 900)]
        let engine = MixerEngine(
            snapshotLoader: { .init(apps: apps, outputUID: "synthetic") },
            tapFactory: { _, _, value in
                tap.gains.append(value); return .success(tap)
            })
        defer { engine.shutdown() }
        let surface = AudioMixerSurface(engine: engine, privacyValues: { [:] })
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("audioMixer")))
        let initial = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "audioMixer")),
            providerID: "audioMixer")
        let slider = try #require(initial.rows.first?.sliders?.first)
        let adjusted = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: slider.id, value: 0.4
                ).encoded(providerID: "audioMixer")),
            providerID: "audioMixer")
        #expect(adjusted.rows.first?.sliders?.first?.value == Double(Float(0.4)))
        #expect(tap.gains == [0.4])
        apps = [app(41, pid: 901)]
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: slider.id, value: 0.3
                ).encoded(providerID: "audioMixer"))
        }
        #expect(tap.destroyed == 1)
        #expect(tap.gains == [0.4])
    }

    @Test func filtersPrivacyAndHiddenControlsRejectActions() async throws {
        guard #available(macOS 14.4, *) else { return }
        let engine = MixerEngine(
            snapshotLoader: {
                .init(apps: [app(1), app(2)], outputUID: "synthetic")
            },
            tapFactory: { _, _, _ in
                Issue.record("A filtered action created an audio tap");
                return .failure(.deviceStart(-1))
            })
        defer { engine.shutdown() }
        var privacy: [String: String] = [:]
        let surface = AudioMixerSurface(engine: engine, privacyValues: { privacy })
        let all = surface.snapshot(.init(.ability("audioMixer")))
        var tile = SurfaceTile(.ability("audioMixer"))
        tile.sourceIDs = [try #require(all.sources.first?.id)]
        tile.itemLimit = 1
        tile.hiddenFields = ["volume"]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let result = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "audioMixer")),
            providerID: "audioMixer")
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.sliders == nil)
        #expect(result.rows.first?.actions.isEmpty == true)
        let hidden = try #require(all.rows.first?.sliders?.first?.id)
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: hidden, value: 0
                ).encoded(providerID: "audioMixer"))
        }
        privacy = ["active": "1", "blurStudio": "1"]
        let masked = try SurfaceSnapshot.decode(
            await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "audioMixer")),
            providerID: "audioMixer")
        #expect(masked.rows.isEmpty)
        #expect(masked.sources.isEmpty)
        #expect(masked.message == "Hidden while presenting.")
    }

    @Test func shutdownRejectsLateActionsAndNonfiniteGains() async throws {
        guard #available(macOS 14.4, *) else { return }
        var discoveries = 0
        let engine = MixerEngine(
            snapshotLoader: {
                discoveries += 1
                return .init(apps: [app(1)], outputUID: "synthetic")
            },
            tapFactory: { _, _, _ in
                Issue.record("Invalid gain created an audio tap"); return .failure(.deviceStart(-1))
            })
        engine.refresh()
        let current = try #require(engine.apps.first)
        engine.setVolume(current, .nan)
        engine.setVolume(current, .infinity)
        #expect(engine.apps.first?.volume == 1)
        engine.shutdown()
        engine.viewAppeared()
        engine.refresh()
        #expect(discoveries == 1)
        #expect(!engine.isMonitoring)
        let surface = AudioMixerSurface(engine: engine)
        await #expect(throws: (any Error).self) {
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(
                    target: .home, tile: .init(.ability("audioMixer"))
                ).encoded(providerID: "audioMixer"))
        }
    }

    @Test func actualMixerViewFitsCompactRegularAndZoomedWindows() throws {
        guard #available(macOS 14.4, *) else { return }
        _ = NSApplication.shared
        let engine = MixerEngine(
            snapshotLoader: {
                .init(apps: [app(1)], outputUID: "synthetic")
            }, tapFactory: { _, _, _ in .failure(.deviceStart(-1)) })
        defer { engine.shutdown(); UIScale.apply(1) }
        engine.refresh()
        for (width, zoom) in [(360.0, 1.0), (980.0, 1.0), (420.0, 1.35)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(
                    rootView: AudioMixerView(engine: engine, monitorsWhileVisible: false)
                        .environment(\.colorScheme, scheme)
                        .environment(\.compactLayout, width / zoom < 720)
                        .frame(width: width, height: 360))
                view.frame = NSRect(x: 0, y: 0, width: width, height: 360)
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.width <= width + 1)
                #expect(view.fittingSize.width > 0)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0)
            }
        }
    }

    private func app(_ objectID: UInt32, pid: Int32 = 900) -> MixerApp {
        .init(
            objectID: objectID, pid: pid, bundleID: "org.example.audio.\(objectID)",
            name: "Synthetic audio \(objectID)", icon: nil, volume: 1)
    }
}
