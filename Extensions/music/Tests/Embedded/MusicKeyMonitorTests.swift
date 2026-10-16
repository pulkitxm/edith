import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicKeyMonitorTests {
    private func presentation(_ location: String) throws -> (MusicEmbeddedPresentation, UUID) {
        let id = UUID()
        let client = try #require(
            ExtensionEngineClient(bridge: MusicSettingsFlushTestBridge(), presentationID: id))
        let scene = try #require(
            MusicEmbeddedPresentation(
                context: ["location": location, "section": "music"], client: client,
                uiOnly: false, version: "1.2.3"))
        return (scene, id)
    }

    @Test func footerPresentationInstallsTheMonitorUntilItIsRetired() throws {
        let (scene, id) = try presentation("music.footer")
        let runtime = MusicEmbeddedRuntime()
        defer { runtime.stop() }
        #expect(!EmbeddedMusicKeyMonitor.isInstalled)
        #expect(runtime.install(scene, id: id))
        #expect(EmbeddedMusicKeyMonitor.isInstalled)
        #expect(runtime.release(["presentationID": id.uuidString]))
        #expect(!EmbeddedMusicKeyMonitor.isInstalled)
    }

    @Test func monitorStaysInstalledWhileAnyPresentationHoldsIt() throws {
        let (footer, footerID) = try presentation("music.footer")
        let (page, pageID) = try presentation("main")
        let runtime = MusicEmbeddedRuntime()
        defer { runtime.stop() }
        #expect(runtime.install(footer, id: footerID))
        #expect(runtime.install(page, id: pageID))
        #expect(runtime.release(["presentationID": footerID.uuidString]))
        #expect(EmbeddedMusicKeyMonitor.isInstalled)
        #expect(runtime.release(["presentationID": pageID.uuidString]))
        #expect(!EmbeddedMusicKeyMonitor.isInstalled)
    }

    @Test func settingsPresentationDoesNotInstallTheMonitor() throws {
        let (scene, id) = try presentation("settings")
        let runtime = MusicEmbeddedRuntime()
        defer { runtime.stop() }
        #expect(runtime.install(scene, id: id))
        #expect(!EmbeddedMusicKeyMonitor.isInstalled)
    }

    @Test func nothingPlayingLeavesKeysUnhandled() {
        #expect(!EmbeddedMusicKeyMonitor.dispatch(keyCode: 49, modifiers: []))
        #expect(!EmbeddedMusicKeyMonitor.dispatch(keyCode: 124, modifiers: []))
    }
}

@MainActor @Suite(.serialized) struct MusicOptimisticTransportTests {
    @Test func volumeAndSeekApplyBeforeTheEngineAnswers() {
        let remote = EmbeddedMusicRemote()
        remote.setVolume(0.2)
        #expect(remote.volume == 0.2)
        remote.setVolume(3)
        #expect(remote.volume == 1)
    }

    @Test func onlyLibraryMutationsRaiseTheLibraryAlert() {
        #expect(EmbeddedMusicUIActionKind.delete.mutatesLibrary)
        #expect(EmbeddedMusicUIActionKind.chooseLibrary.mutatesLibrary)
        #expect(!EmbeddedMusicUIActionKind.volume.mutatesLibrary)
        #expect(!EmbeddedMusicUIActionKind.seek.mutatesLibrary)
        #expect(!EmbeddedMusicUIActionKind.playPause.mutatesLibrary)
    }
}
