import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioEmbeddedActionTests {
    @Test func surfaceOpenRoutesOriginalEmbeddedEditorWithoutWorkerWindowNotification() async throws
    {
        let root = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await VideoEditorServiceTests.movie(in: root)
        let source = root.appendingPathComponent("synthetic.png")
        let suite = "studio.embedded.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StudioModel(defaults: defaults, loadsState: false)
        let remoteFacade = StudioUIFacade { command, payload in
            try await StudioUICommands.execute(command, payload: payload, model: engine)
        }
        let remote = StudioModel(loadsState: false, facade: remoteFacade)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: ExtensionPresentation.showWindowNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { notifications += 1 } }
        defer {
            NotificationCenter.default.removeObserver(observer); engine.shutdown();
            remote.shutdown()
        }
        try StudioMediaLibrary.add([source], defaults: defaults)
        try StudioSurface.perform("open:" + StudioSurface.identifier(source), model: engine)
        let state: StudioUIState = try await remoteFacade.read("studio.ui.state")
        let presentation = try #require(state.presentation)
        #expect(try presentation.route == .imageEditor(source))
        remote.apply(state)
        #expect(remote.route == .imageEditor(source) && notifications == 0)
        remote.goHome()
        remote.apply(state)
        #expect(remote.route == .home)
        try StudioSurface.perform("open:" + StudioSurface.identifier(source), model: engine)
        let next: StudioUIState = try await remoteFacade.read("studio.ui.state")
        #expect(next.presentation?.token != presentation.token)
        remote.apply(next)
        #expect(remote.route == .imageEditor(source) && notifications == 0)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func videoFacadeRejectsMalformedDocumentAndForeignFileURLs() throws {
        var malformed = VideoProject.create()
        malformed.root["assets"] = "invalid"
        let value = try StudioUIVideoProject(malformed)
        #expect(throws: (any Error).self) { _ = try value.value }
        var foreign = VideoProject.create()
        foreign.fileURL = URL(string: "https://example.invalid/synthetic.openscreen")
        let invalid = try StudioUIVideoProject(foreign)
        #expect(throws: ExtensionPeerError.self) { _ = try invalid.value }
        let presentation = try #require(
            StudioUIPresentation(
                route: .imageEditor(URL(string: "https://example.invalid/synthetic.png")!),
                tab: .files, selection: []))
        #expect(throws: ExtensionPeerError.self) { _ = try presentation.route }
    }
}
