import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor final class MusicEmbeddedRuntime {
    private(set) var configured = false
    private var presentations: [UUID: MusicEmbeddedPresentation] = [:]
    private var closing: [UUID: MusicEmbeddedPresentation] = [:]
    static let presentationLimit = 16

    func configure(_ input: NSDictionary) -> NSDictionary {
        guard let configuration = ExtensionUIConfiguration(context: input),
            configuration.extensionID == "music",
            let version = Bundle(for: MusicEmbeddedRuntime.self).object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            !version.isEmpty,
            let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
            let scene = MusicEmbeddedPresentation(
                context: input, client: configuration.engineClient,
                uiOnly: configuration.uiOnly, version: version)
        else { return ["ok": false] }
        return install(scene, id: id) ? ["ok": true] : ["ok": false]
    }

    var presentationCount: Int { presentations.count + closing.count }

    func install(_ scene: MusicEmbeddedPresentation, id: UUID) -> Bool {
        for key in Array(presentations.keys) where presentations[key]?.isRetained == false {
            presentations.removeValue(forKey: key)?.shutdown()
        }
        guard closing[id] == nil,
            presentationCount < Self.presentationLimit || presentations[id] != nil
        else {
            scene.shutdown(); return false
        }
        presentations.removeValue(forKey: id)?.shutdown()
        presentations[id] = scene
        scene.attach()
        configured = true
        return true
    }

    func view(_ input: NSDictionary) -> NSViewController? {
        guard configured, let value = input["presentationID"] as? String,
            let id = UUID(uuidString: value), let scene = presentations[id], scene.matches(input)
        else { return nil }
        return scene.controller()
    }

    func release(_ input: NSDictionary) -> Bool {
        guard let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
            let scene = presentations.removeValue(forKey: id)
        else { return false }
        scene.shutdown(); configured = !presentations.isEmpty
        return true
    }

    func prepareToClose(_ id: UUID) async {
        guard let scene = presentations.removeValue(forKey: id) else { return }
        closing[id] = scene
        scene.beginShutdown()
        if scene.isMain { EmbeddedMusicVideoSession.stopAll() }
        if presentations.isEmpty {
            EmbeddedMusicVideoSession.stopAll(); EmbeddedMusicBrowserSession.stopAll()
        }
        await EmbeddedMusicVideoSession.drainAll()
        await EmbeddedMusicBrowserSession.drainAll()
        scene.shutdown(); closing[id] = nil; configured = !presentations.isEmpty
    }

    func stop() {
        for scene in presentations.values { scene.shutdown() }
        for scene in closing.values { scene.shutdown() }
        presentations.removeAll(); closing.removeAll(); configured = false
    }
}

@MainActor final class MusicEmbeddedPresentation {
    private let client: ExtensionEngineClient?
    private let uiOnly: Bool
    private let location: String
    private let section: String
    private let tile: Data?
    private let target: String?
    private let notch: EmbeddedMusicNotchRoute?
    private let notchModel: EmbeddedMusicNotchModel?
    private var pending = true
    private weak var presentedController: NSViewController?
    private var closed = false
    private var detached = false
    var isMain: Bool { location == "main" }
    var isRetained: Bool { !closed && (pending || presentedController != nil) }

    init?(
        context: NSDictionary, client: ExtensionEngineClient?, uiOnly: Bool, version: String? = nil
    ) {
        guard let location = context["location"] as? String,
            let section = context["section"] as? String
        else { return nil }
        let tile = context["tile"] as? Data
        let target = context["target"] as? String
        let notch = EmbeddedMusicNotchRoute(context: context)
        if uiOnly {
            guard location == "settings", section == "music", context["tile"] == nil,
                context["target"] == nil,
                client == nil
            else { return nil }
        } else if location == "notch" {
            guard client != nil, notch != nil else { return nil }
        } else if location == "home" {
            guard client != nil, section == "music", target == "home", let tile,
                tile.count <= 65_536,
                let value = try? JSONDecoder().decode(SurfaceTile.self, from: tile),
                value.widget == .music,
                (try? SurfaceSnapshotRequest(target: .home, tile: value).encoded(
                    providerID: "music")) != nil
            else { return nil }
        } else {
            guard client != nil, context["tile"] == nil, context["target"] == nil,
                EmbeddedMusicSceneRoute(context) != nil
            else { return nil }
        }
        self.location = location; self.section = section; self.tile = tile; self.target = target
        self.uiOnly = uiOnly; self.client = client; self.notch = notch
        if let notch, let client {
            notchModel = EmbeddedMusicNotchModel(
                request: notch.request, expectedVersion: version,
                invoke: { operation, payload in
                    try await client.invoke(operation, payload: payload)
                })
        } else {
            notchModel = nil
        }
    }

    func attach() {
        if let client { EmbeddedMusicRemote.shared.configure(client) }
    }

    func matches(_ context: NSDictionary) -> Bool {
        !closed && (context["tile"] == nil || context["tile"] is Data)
            && (context["target"] == nil || context["target"] is String)
            && context["location"] as? String == location
            && context["section"] as? String == section
            && context["tile"] as? Data == tile && context["target"] as? String == target
    }

    func controller() -> NSViewController? {
        guard !closed else { return nil }
        if let presentedController { return presentedController }
        let controller: NSViewController?
        if uiOnly {
            controller = NSHostingController(
                rootView: ExtensionPageHost { EmbeddedMusicDisabledSettings() })
        } else if let notch, let notchModel {
            controller = NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicNotchScene(route: notch, model: notchModel)
                })
        } else if location == "home", let tile,
            let value = try? JSONDecoder().decode(SurfaceTile.self, from: tile)
        {
            controller = NSHostingController(
                rootView: ExtensionPageHost {
                    EmbeddedMusicSceneLoad { EmbeddedMusicHomeScene(tile: value) }
                })
        } else {
            controller = EmbeddedMusicAuxiliaryScenes.controller([
                "location": location, "section": section,
            ])
        }
        if let controller { presentedController = controller; pending = false }
        return controller
    }

    func beginShutdown() {
        closed = true; pending = false; notchModel?.shutdown()
    }

    func shutdown() {
        beginShutdown()
        guard !detached else { return }
        detached = true
        if let client { EmbeddedMusicRemote.shared.detach(client) }
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
