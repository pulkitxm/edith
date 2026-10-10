import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicHomeCardTests {
        @Test(arguments: [320.0, 640.0])
        func originalPlaybackAndQueueRespectSavedWidgetOptions(width: Double) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let priorFolder = SharedDefaults.store.string(forKey: MusicStorage.musicFolderPathKey)
            MusicStorage.setMusicDirectory(root)
            let accountID = "test.music.home." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: accountID))
            let accounts = MusicAccounts(
                defaults: defaults,
                spotify: MusicSpotifySession(libraryURL: nil, defaults: defaults), pauseLocal: {})
            let tracks = ["Synthetic current.mp3", "Synthetic queued.mp3"].map {
                Track(url: root.appendingPathComponent($0), relativePath: $0)
            }
            let remote = MusicRemote(
                scanFavourites: { [] }, listSubfolders: { _ in [] },
                listFolder: { path in
                    .init(
                        folder: .init(url: root.appendingPathComponent(path), relativePath: path),
                        folders: [], tracks: [])
                }, catalog: { tracks })
            defer {
                remote.stop(); accounts.shutdown()
                defaults.removePersistentDomain(forName: accountID)
                SharedDefaults.store.set(priorFolder, forKey: MusicStorage.musicFolderPathKey)
                TrackMeta.invalidateCaches()
                try? FileManager.default.removeItem(at: root)
            }
            remote.rescan()
            for _ in 0..<100 where remote.tracks.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(remote.tracks.count == 2)
            remote.apply([
                "track": tracks[0].relativePath, "isPlaying": false, "elapsed": 42.0,
                "duration": 180.0,
            ])
            _ = TestWindowHost.application
            let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
                NSAccessibility.Attribute(rawValue: $0)
            }
            let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
            for attribute in attributes {
                NSApp.accessibilitySetValue(true, forAttribute: attribute)
            }
            defer {
                for (attribute, value) in zip(attributes, previous) {
                    NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
                }
            }
            var opened = 0
            var tile = SurfaceTile(.music)
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            let window = TestWindowHost.window(
                contentRect: .init(x: 0, y: 0, width: width, height: 400))
            window.contentView = host
            defer { window.contentView = nil }
            func render() async {
                host.rootView = AnyView(
                    HomeMusicCard(
                        dark: false, remote: remote, accounts: accounts, open: { opened += 1 }
                    )
                    .environment(
                        \.surfacePresentation,
                        SurfacePresentation(tile: tile, layout: .standard(.home))
                    )
                    .environment(\.automaticViewActionsEnabled, false)
                    .transaction { $0.animation = nil })
                for _ in 0..<8 {
                    window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            await render()
            #expect(find(host, label: tracks[0].title) != nil)
            #expect(find(host, label: tracks[1].title) != nil)
            #expect(find(host, label: "0:42 / 3:00") != nil)
            #expect(find(host, label: "Play or pause music") != nil)
            #expect(find(host, label: "Next music track") != nil)
            let open = try #require(find(host, label: "Open Music"))
            _ = (open as AnyObject).accessibilityPerformPress?()
            #expect(opened == 1)
            remote.apply([
                "track": tracks[0].relativePath, "isPlaying": false, "elapsed": 75.0,
                "duration": 180.0,
            ])
            await render()
            #expect(find(host, label: "1:15 / 3:00") != nil)
            tile.showActions = false
            tile.hiddenFields = ["queue", "progress", "artwork"]
            await render()
            #expect(find(host, label: "Open Music") == nil)
            #expect(find(host, label: "Play or pause music") == nil)
            #expect(find(host, label: "Next music track") == nil)
            #expect(find(host, label: tracks[1].title) == nil)
            #expect(find(host, label: "1:15 / 3:00") == nil)
            #expect(find(host, label: tracks[0].title) != nil)
            #expect(!window.isVisible)
            #expect(!TestWindowHost.isExposedOnDesktop(window))
        }

        private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
            guard depth < 64 else { return nil }
            if (node as AnyObject).accessibilityLabel?() == label { return node }
            let selector = NSSelectorFromString("accessibilityValue")
            if node.responds(to: selector),
                node.perform(selector)?.takeUnretainedValue() as? String == label
            {
                return node
            }
            for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
                if let found = find(child, label: label, depth: depth + 1) { return found }
            }
            for child in (node as? NSView)?.subviews ?? [] {
                if let found = find(child, label: label, depth: depth + 1) { return found }
            }
            return nil
        }
    }
}
