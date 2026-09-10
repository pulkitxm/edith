import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct AudioControlsRenderTests {
    @Test func deviceSettingsRenderWithSyntheticHardware() throws {
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.Audio.enabled
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let snapshot = AudioDeviceSnapshot(
            devices: [
                AudioDeviceDescriptor(
                    uid: "sample-microphone", name: "Studio Microphone", supportsInput: true,
                    supportsOutput: false, isDefaultInput: true, isDefaultOutput: false,
                    isHeadphones: false),
                AudioDeviceDescriptor(
                    uid: "sample-headphones", name: "Studio Headphones", supportsInput: false,
                    supportsOutput: true, isDefaultInput: false, isDefaultOutput: true,
                    isHeadphones: true),
            ], defaultInputUID: "sample-microphone", defaultOutputUID: "sample-headphones")
        let view = Form { AudioControlsRows(snapshot: snapshot) }
            .formStyle(.grouped)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 780)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 780)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 680)
        #expect(data.count > 15_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("audio-controls.png"))
        }
    }
}
