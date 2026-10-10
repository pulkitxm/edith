import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor final class MusicEmbeddedRuntime {
    private(set) var configured = false
    private var client: ExtensionEngineClient?
    private var uiOnly = false

    func configure(_ input: NSDictionary) -> NSDictionary {
        guard let configuration = ExtensionUIConfiguration(context: input) else {
            return ["ok": false]
        }
        stop()
        self.client = configuration.engineClient
        uiOnly = configuration.uiOnly
        if let client = configuration.engineClient { EmbeddedMusicRemote.shared.configure(client) }
        configured = true
        return ["ok": true]
    }

    func view(_ input: NSDictionary) -> NSViewController? {
        guard configured else { return nil }
        if uiOnly {
            guard input["location"] as? String == "settings", input["section"] as? String == "music"
            else { return nil }
            return NSHostingController(
                rootView: ExtensionPageHost { EmbeddedMusicDisabledSettings() })
        }
        if input["location"] as? String == "home" {
            guard input["section"] as? String == "music", let data = input["tile"] as? Data,
                data.count <= 65_536,
                let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                tile.widget == .music
            else { return nil }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicHomeScene(tile: tile) }
                })
        }
        return EmbeddedMusicAuxiliaryScenes.controller(input)
    }

    func stop() {
        if let client { EmbeddedMusicRemote.shared.detach(client) }
        client = nil; configured = false
    }
}

private struct EmbeddedMusicDisabledSettings: View {
    var body: some View {
        PageWorkspace {
            PageHeader("Music settings")
        } content: {
            PageNotice(
                "Enable the Music extension to configure its library, accounts and playback.",
                tone: .information
            )
            .padding(UIScale.pt(24))
        }
    }
}
