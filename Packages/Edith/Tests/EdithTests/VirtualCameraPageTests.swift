import AVFoundation
import AppKit
import CoreImage
import CoreText
import EdithCameraSupport
import Foundation
import SwiftUI
import SystemExtensions
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct VirtualCameraPageModelTests {
    static let sources = [
        VirtualCameraSource(id: "cam-a", name: "FaceTime HD Camera", kind: .builtIn),
        VirtualCameraSource(id: "cam-b", name: "Desk View Camera", kind: .deskView),
    ]

    static func model(
        access: AVAuthorizationStatus = .denied,
        sourceProvider: (() -> [VirtualCameraSource])? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> (VirtualCameraPageModel, UserDefaults, String) {
        let name = "test.edith.virtual-camera-page.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let model = VirtualCameraPageModel(
            defaults: defaults,
            pipeline: VirtualCameraPipeline(
                state: VirtualCameraState(), outputSize: CGSize(width: 320, height: 180)),
            extensionManager: VirtualCameraExtensionManager(
                environment: VirtualCameraExtensionEnvironment(
                    bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"),
                    hasInstallEntitlement: { false }, deviceVisible: { false })),
            accessProvider: { access }, sourceProvider: sourceProvider ?? { sources },
            previewBus: VirtualCameraPreviewBus(
                file: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "camera-preview-\(UUID().uuidString).bin"),
                unlinkOnClose: true), clock: clock)
        return (model, defaults, name)
    }

    @Test func missingCameraExplainsThePreviewAndRefreshRecovers() throws {
        var available: [VirtualCameraSource] = []
        let (model, defaults, name) = Self.model(access: .authorized, sourceProvider: { available })
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!model.hasNoCameraSource)
        #expect(model.previewLoadingTitle == "Finding cameras")
        model.refreshSources()
        #expect(model.hasNoCameraSource)
        let host = try auditHost(
            VirtualCameraStage(model: model, dark: true), size: CGSize(width: 800, height: 450))
        #expect(try auditText(host).contains("No camera connected"))
        #expect(try auditText(host).contains("Refresh cameras"))
        available = Self.sources
        model.refreshSources()
        #expect(!model.hasNoCameraSource)
        #expect(model.sources == Self.sources)
        model.pause(.blank)
        #expect(!model.hasNoCameraSource)
    }

    @Test func editsPersistAfterTheDebouncedSave() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2)
        model.updateComposition { $0.look.preset = .film }
        #expect(model.composition.framing.zoom == 2)
        #expect(VirtualCameraStore.load(defaults).composition.look.preset == .natural)
        model.flushSave()
        let stored = VirtualCameraStore.load(defaults)
        #expect(stored.composition.framing.zoom == 2)
        #expect(stored.composition.look.preset == .film)
    }

    @Test func multipleAccordionSectionsSurviveReopening() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setInspectorExpanded(.audio, false)
        model.setInspectorExpanded(.voice, true)
        model.setInspectorExpanded(.devices, true)
        model.setInspectorExpanded(.frame, true)
        #expect(model.expandedInspectorSections == [.voice, .devices, .frame])
        let reopened = VirtualCameraPageModel(
            defaults: defaults, accessProvider: { .denied }, sourceProvider: { Self.sources })
        #expect(reopened.tab == .frame)
        #expect(reopened.expandedInspectorSections == [.voice, .devices, .frame])
        reopened.setInspectorExpanded(.voice, false)
        #expect(reopened.expandedInspectorSections == [.devices, .frame])
        let closed = VirtualCameraPageModel(
            defaults: defaults, accessProvider: { .denied }, sourceProvider: { Self.sources })
        #expect(closed.expandedInspectorSections == [.devices, .frame])
        closed.setInspectorExpanded(.devices, false)
        closed.setInspectorExpanded(.frame, false)
        let empty = VirtualCameraPageModel(
            defaults: defaults, accessProvider: { .denied }, sourceProvider: { Self.sources })
        #expect(empty.expandedInspectorSections.isEmpty)
    }

    @Test func leavingThePageDoesNotOverwriteAHelperBackgroundChange() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.appear()
        model.updateComposition { $0.background.mode = .color }
        model.flushSave()
        var external = model.state
        external.composition.background.mode = .none
        VirtualCameraStore.save(external, to: defaults)
        model.disappear()
        #expect(VirtualCameraStore.load(defaults).composition.background.mode == .none)
        model.appear()
        defer { model.disappear() }
        #expect(model.composition.background.mode == .none)
    }

    @Test func helperStatusRepairsStaleDefaultsAndAMissedStateNotification() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.updateComposition { $0.background.mode = .color }
        model.update { $0.media.audioEnabled = true }
        model.flushSave()
        var external = model.state
        external.composition.background.mode = .none
        external.media.audioEnabled = false
        external.audio.enabled = true
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false,
                state: external))
        #expect(model.composition.background.mode == .none)
        #expect(!model.state.media.audioEnabled)
        #expect(model.state.audio.enabled)
        model.setZoom(2)
        model.flushSave()
        #expect(VirtualCameraStore.load(defaults).composition.background.mode == .none)
        #expect(VirtualCameraStore.load(defaults).audio.enabled)
    }

    @Test func helperStatusDoesNotDiscardPendingWindowEdits() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        let previous = model.state
        model.updateComposition { $0.background.mode = .blur }
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false,
                state: previous))
        model.flushSave()
        #expect(VirtualCameraStore.load(defaults).composition.background.mode == .blur)
    }

    @Test func meetingTogglePausesVideoWithoutReplacingItAndResumesAllPauseModes() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.update { $0.media = VirtualCameraMedia(kind: .video, path: "/tmp/demo.mp4") }
        model.toggleMeetingPlayback()
        #expect(!model.meetingPlaying)
        #expect(model.state.media.playback == .paused)
        #expect(model.state.privacy == .live)
        #expect(model.statusHeadline == "Paused")
        #expect(model.state.media.path == "/tmp/demo.mp4")
        for mode in [VirtualCameraPrivacy.freeze, .card, .blank, .stopped] {
            model.pause(mode)
            model.toggleMeetingPlayback()
            #expect(model.meetingPlaying)
            #expect(model.state.media.playback == .playing)
        }
        #expect(VirtualCameraStore.load(defaults) == model.state)
    }

    @Test func meetingToggleFreezesCameraAndScreenInsteadOfStoppingCapture() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        for kind in [VirtualCameraMediaKind.camera, .screen] {
            model.update { $0.media.kind = kind }
            model.toggleMeetingPlayback()
            #expect(model.state.privacy == .freeze)
            #expect(!model.meetingPlaying)
            model.toggleMeetingPlayback()
            #expect(model.state.privacy == .live)
            #expect(model.meetingPlaying)
        }
    }

    @Test func dragEditsSaveDuringEventTracking() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2)
        model.pan(by: CGSize(width: 80, height: 0), in: CGSize(width: 320, height: 180))
        RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.3))
        #expect(VirtualCameraStore.load(defaults).composition.framing == model.composition.framing)
    }

    @Test func dragAndZoomFollowTheGeometry() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2)
        let before = model.composition.framing.centerX
        model.pan(by: CGSize(width: 100, height: 0), in: CGSize(width: 960, height: 540))
        #expect(model.composition.framing.centerX < before)
        model.zoom(by: 2, anchor: CGPoint(x: 0.5, y: 0.5))
        #expect(model.composition.framing.zoom == 4)
        model.updateComposition { $0.framing.autoFrame = .close }
        model.resetFraming()
        #expect(model.composition.framing == VirtualCameraFraming(autoFrame: .close))
    }

    @Test func rotationWrapsAround() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.rotate(clockwise: false)
        #expect(model.composition.framing.quarterTurns == 3)
        model.rotate(clockwise: true)
        model.rotate(clockwise: true)
        #expect(model.composition.framing.quarterTurns == 1)
        #expect(model.sourceSize == CGSize(width: 1080, height: 1920))
    }

    @Test func scenesCanBeSavedRenamedAndRemoved() throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(3)
        model.saveScene(named: "Whiteboard")
        let scene = try #require(model.state.scenes.last)
        #expect(scene.name == "Whiteboard")
        #expect(model.state.activeSceneID == scene.id)
        model.saveScene(named: "whiteboard")
        #expect(model.errorMessage == "A scene named whiteboard already exists.")
        model.errorMessage = nil
        model.renameScene(scene, to: "Board")
        #expect(model.state.scenes.last?.name == "Board")
        model.duplicateScene(try #require(model.state.scenes.last))
        #expect(model.state.scenes.map(\.name).suffix(2) == ["Board", "Board 2"])
        model.apply(model.state.scenes[1])
        #expect(model.composition.framing.zoom == 1.6)
        model.setZoom(1.8)
        #expect(model.state.activeSceneIsModified)
        model.updateScene(model.state.scenes[1])
        #expect(!model.state.activeSceneIsModified)
        model.moveScene(model.state.scenes[0], by: 1)
        #expect(model.state.scenes[1].name == "Full frame")
        model.deleteScene(try #require(model.state.scenes.last))
        #expect(model.state.scenes.count == 3)
        #expect(model.suggestedSceneName() == "Scene")
    }

    @Test func pausingAndCamerasUpdateTheState() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.refreshSources()
        #expect(model.selectedSource?.id == "cam-a")
        model.selectSource(Self.sources[1])
        #expect(model.selectedSource?.name == "Desk View Camera")
        model.pause(.freeze)
        #expect(model.state.privacy == .freeze)
        model.resume()
        #expect(model.state.privacy == .live)
    }

    @Test func screenPickerPersistsTheSourceAndItsAudioChoice() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2)
        model.pause(.freeze)
        model.selectScreen(
            TimeLapseSourceSelection(
                mode: "windows", displays: [5], windows: [42], systemAudio: true))
        #expect(model.state.media.kind == .screen)
        #expect(model.state.media.screenID == "window:42")
        #expect(model.state.media.audioEnabled)
        #expect(model.state.privacy == .live)
        #expect(model.composition.framing == VirtualCameraFraming())
        #expect(VirtualCameraStore.load(defaults).media == model.state.media)
        #expect(model.screenSelection.windows == [42])
        #expect(model.screenSelection.displays.isEmpty)
        model.selectScreen(
            TimeLapseSourceSelection(
                mode: "displays", displays: [5], windows: [], systemAudio: false))
        #expect(model.state.media.screenID == "display:5")
        #expect(!model.state.media.audioEnabled)
        #expect(model.screenSelection.displays == [5])
        let previous = model.state
        model.selectScreen(
            TimeLapseSourceSelection(
                mode: "windows", displays: [], windows: [1, 2], systemAudio: true))
        #expect(model.state == previous)
    }

    @Test func removingAnImageTurnsItsFeatureOff() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.updateComposition {
            $0.background = VirtualCameraBackground(mode: .image, imagePath: "/tmp/b.png")
            $0.overlays.logo = VirtualCameraLogo(enabled: true, imagePath: "/tmp/l.png")
        }
        model.removeImage(for: .background)
        model.removeImage(for: .logo)
        #expect(model.composition.background.mode == .none)
        #expect(model.composition.background.imagePath == nil)
        #expect(!model.composition.overlays.logo.enabled)
        #expect(VirtualCameraStore.load(defaults).composition.background.mode == .none)
    }

    @Test func importingRejectsFilesThatAreNotImages() throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.importImage(file, for: .logo)
        #expect(model.errorMessage?.contains("not an image") == true)
        #expect(model.composition.overlays.logo.imagePath == nil)
    }

    @Test func unacquiredCameraPageCannotReleaseAnotherHostsPreview() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        var first = VirtualCameraPageAttachment()
        var second = VirtualCameraPageAttachment()
        first.begin()
        first.acquire(model)
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false,
                obsAvailable: true, route: .obs, live: true, state: model.state))
        second.release(model)
        second.acquire(model)
        #expect(!second.acquired)
        #expect(model.showsHelperPreview)
        second.begin()
        second.acquire(model)
        second.release(model)
        second.release(model)
        #expect(model.showsHelperPreview)
        first.release(model)
        #expect(!model.previewRunning)
    }

    @Test func initialStatusWaitsBeforeStartingLocalCapture() {
        let (model, defaults, name) = Self.model(access: .authorized)
        defer {
            model.disappear()
            defaults.removePersistentDomain(forName: name)
        }
        model.appear()
        #expect(!model.previewRunning)
        #expect(model.previewLoadingTitle == "Connecting to Edith Bar")
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false,
                obsAvailable: true, route: .obs, live: true, state: model.state))
        #expect(model.showsHelperPreview)
    }

    @Test func aLiveHelperReplacesTheWindowCamera() {
        let (model, defaults, name) = Self.model()
        defer {
            model.disappear()
            defaults.removePersistentDomain(forName: name)
        }
        model.appear()
        #expect(!model.showsHelperPreview)
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false, obsAvailable: true,
                route: .obs, live: true, state: model.state))
        #expect(model.showsHelperPreview)
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false, obsAvailable: true,
                route: .obs, live: false, state: model.state))
        #expect(!model.showsHelperPreview)
    }

    @Test func completeStopClearsPreviewAndSurvivesReopeningAndLateStatus() throws {
        let (model, defaults, name) = Self.model()
        defer {
            model.disappear()
            defaults.removePersistentDomain(forName: name)
        }
        model.appear()
        let live = VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: false, obsAvailable: true,
            route: .obs, live: true, state: model.state)
        model.receive(live)
        model.showPreviewFrame(try #require(VirtualCameraFixtures.quadrants()))
        #expect(model.previewRunning)
        model.pause(.stopped)
        #expect(!model.previewRunning)
        #expect(model.display.current == nil)
        #expect(!model.isLive)
        #expect(model.statusHeadline == "Stopped")
        #expect(VirtualCameraStore.load(defaults).privacy == .stopped)
        model.receive(live)
        model.setZoom(2)
        model.disappear()
        model.appear()
        #expect(model.state.privacy == .stopped)
        #expect(!model.previewRunning)
        #expect(!model.showsHelperPreview)
        model.resume()
        #expect(model.state.privacy == .live)
        #expect(model.showsHelperPreview)
    }

    @Test func statusCombinesTheHelperAndTheState() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.injectForTesting(snapshot: nil, sources: [])
        #expect(model.statusHeadline == "Edith Bar is not answering")
        var snapshot = VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: true, route: .edithCamera,
            clients: [VirtualCameraClient(id: "us.zoom.xos", name: "zoom.us")], live: true,
            format: .hd720, state: model.state)
        model.receive(snapshot)
        #expect(model.isLive)
        #expect(model.statusHeadline == "Live in zoom.us")
        #expect(model.outputSize == CGSize(width: 1280, height: 720))
        snapshot.live = false
        model.receive(snapshot)
        #expect(!model.isLive)
        model.receive(nil)
        #expect(model.snapshot == snapshot)
    }

    @Test func appearingKeepsEditsThatWereNotSavedYet() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2.5)
        model.appear()
        defer { model.disappear() }
        #expect(model.composition.framing.zoom == 2.5)
        #expect(VirtualCameraStore.load(defaults).composition.framing.zoom == 2.5)
        var stored = VirtualCameraStore.load(defaults)
        stored.composition.framing.zoom = 3
        VirtualCameraStore.save(stored, to: defaults)
        model.reloadState()
        #expect(model.composition.framing.zoom == 3)
    }

    @Test func lookThumbnailsFollowTheReferenceFrame() async throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        let input = try #require(VirtualCameraFixtures.quadrants())
        model.renderPreview(from: input)
        #expect(model.lookThumbnails.isEmpty)
        model.tab = .look
        await model.waitForLookThumbnails()
        #expect(model.lookThumbnails.count == VirtualCameraLookPreset.allCases.count)
        let reference = try #require(model.previewReference)
        model.updateLookThumbnails(from: reference)
        await model.waitForLookThumbnails()
        #expect(model.lookThumbnails[.noir]?.width == reference.width)
    }

    @Test func previewFramesReachTheDisplay() throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        let input = try #require(VirtualCameraFixtures.quadrants())
        model.renderPreview(from: input)
        let shown = try #require(model.display.current)
        #expect(model.hasPreviewFrame)
        #expect(CVPixelBufferGetWidth(shown) == 320)
        model.display.clear()
        #expect(model.display.current == nil)
        #expect(!model.hasPreviewFrame)
    }

    @Test func coldHelperPreviewProvidesLookThumbnailsWithoutLocalCapture() async throws {
        let name = "test.edith.camera-helper-looks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "camera-helper-looks-\(UUID().uuidString).bin")
        let reader = VirtualCameraPreviewBus(file: file, unlinkOnClose: true)
        let writer = VirtualCameraPreviewBus(file: file)
        let model = VirtualCameraPageModel(
            defaults: defaults, accessProvider: { .denied }, sourceProvider: { [] },
            previewBus: reader)
        defer {
            model.disappear()
            reader.close()
            writer.close()
            defaults.removePersistentDomain(forName: name)
        }
        model.tab = .look
        model.appear()
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false,
                obsAvailable: true, route: .obs, live: true, state: model.state))
        let frame = try #require(VirtualCameraFixtures.quadrants())
        let image = CIImage(cvPixelBuffer: frame)
        let reference = try #require(CIContext().createCGImage(image, from: image.extent))
        writer.setWanted(true)
        writer.publish(frame, reference: reference)
        for _ in 0..<50 {
            if model.previewReference != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await model.waitForLookThumbnails()
        #expect(model.showsHelperPreview)
        #expect(model.previewReference?.width == VirtualCameraPreviewBus.referenceWidth)
        #expect(model.lookThumbnails.count == VirtualCameraLookPreset.allCases.count)
        #expect(!model.previewStatistics.usingCamera)
    }

    @Test func stalledPreviewShowsActionableFailureAndRetryRestartsIt() throws {
        var time = 0.0
        let (model, defaults, name) = Self.model(clock: { time })
        defer {
            model.disappear()
            defaults.removePersistentDomain(forName: name)
        }
        model.appear()
        model.receive(
            VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: false,
                obsAvailable: true, route: .obs, live: true, state: model.state))
        time = 7
        model.refreshPreviewHealth()
        #expect(model.previewFailure == nil)
        time = 9
        model.refreshPreviewHealth()
        #expect(model.previewFailure != nil)
        #expect(model.previewLoadingTitle == nil)
        let host = try auditHost(
            VirtualCameraStage(model: model, dark: true), size: CGSize(width: 800, height: 450))
        #expect(try auditText(host).contains("Camera preview unavailable"))
        #expect(try auditText(host).contains("Retry camera"))
        model.retryPreview()
        #expect(model.previewFailure == nil)
        #expect(model.showsHelperPreview)
        #expect(model.previewLoadingTitle != nil)
        model.showPreviewFrame(try #require(VirtualCameraFixtures.quadrants()))
        time = 30
        model.refreshPreviewHealth()
        #expect(model.previewFailure == nil)
        #expect(model.previewLoadingTitle == nil)
    }

    @Test func previewFramesArriveDuringEventTracking() throws {
        let display = VirtualCameraPreviewDisplay()
        let buffer = try #require(VirtualCameraFixtures.quadrants())
        display.push(buffer)
        RunLoop.main.add(
            Timer(timeInterval: 0.1, repeats: false) { _ in }, forMode: .eventTracking)
        RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.1))
        #expect(display.current === buffer)
    }
}

@MainActor
@Suite struct VirtualCameraExtensionManagerTests {
    @Test func phasesExplainWhatBlocksTheInstall() {
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: false, inApplications: false,
                deviceVisible: true) == .installed)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: false, entitled: true, inApplications: true,
                deviceVisible: false) == .missingFromBundle)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: false, inApplications: true,
                deviceVisible: false) == .needsSigning)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: true, inApplications: false,
                deviceVisible: false) == .needsApplicationsFolder)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: true, inApplications: true,
                deviceVisible: false) == .notInstalled)
        #expect(VirtualCameraExtensionPhase.notInstalled.canInstall)
        #expect(VirtualCameraExtensionPhase.failed("x").canInstall)
        #expect(!VirtualCameraExtensionPhase.needsSigning.canInstall)
        #expect(!VirtualCameraExtensionPhase.installed.canInstall)
    }

    @Test func refreshReadsTheBundleEntitlementAndDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-bundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Edith.app")
        let extensionURL = app.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(VirtualCameraExtensionManager.identifier).systemextension"
        )
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var visible = false
        var entitled = false
        let manager = VirtualCameraExtensionManager(
            environment: VirtualCameraExtensionEnvironment(
                bundleURL: app, hasInstallEntitlement: { entitled }, deviceVisible: { visible }))
        #expect(manager.extensionBundleURL.standardizedFileURL == extensionURL.standardizedFileURL)
        #expect(!manager.inApplicationsFolder)
        manager.refresh()
        #expect(manager.phase == .needsSigning)
        entitled = true
        manager.refresh()
        #expect(manager.phase == .needsApplicationsFolder)
        visible = true
        manager.refresh()
        #expect(manager.phase == .installed)
        manager.install()
        #expect(manager.phase == .installed)
    }

    @Test func systemExtensionErrorsBecomeGuidance() {
        func message(_ code: OSSystemExtensionError.Code) -> String {
            VirtualCameraExtensionManager.message(
                for: NSError(domain: OSSystemExtensionErrorDomain, code: code.rawValue))
        }
        #expect(message(.missingEntitlement) == VirtualCameraExtensionPhase.needsSigning.detail)
        #expect(
            message(.unsupportedParentBundleLocation)
                == VirtualCameraExtensionPhase.needsApplicationsFolder.detail)
        #expect(message(.extensionNotFound) == VirtualCameraExtensionPhase.missingFromBundle.detail)
        #expect(message(.codeSignatureInvalid).contains("signature"))
        #expect(message(.requestCanceled) == "The request was canceled.")
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(VirtualCameraExtensionManager.message(for: other) == "boom")
        #expect(!VirtualCameraExtensionManager.selfHasEntitlement())
    }

    @Test func detachedRefreshDoesNotBlockOnTheDeviceCheck() async {
        let manager = VirtualCameraExtensionManager(
            environment: VirtualCameraExtensionEnvironment(
                bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"),
                hasInstallEntitlement: { false },
                deviceVisible: {
                    Thread.sleep(forTimeInterval: 0.25)
                    return true
                }))
        let started = ContinuousClock.now
        manager.refreshDetached()
        #expect(started.duration(to: .now) < .milliseconds(100))
        #expect(manager.phase == .checking)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while manager.phase != .installed && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.phase == .installed)
    }
}

@MainActor
@Suite struct VirtualCameraPreviewViewTests {
    @Test func previewSubscribersReceiveFramesAndDetachIndependently() throws {
        let display = VirtualCameraPreviewDisplay()
        let first = VirtualCameraPreviewNSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let second = VirtualCameraPreviewNSView(frame: first.frame)
        let initial = try #require(VirtualCameraFixtures.quadrants())
        display.attach(first)
        display.attach(second)
        display.push(initial)
        display.flush()
        let initialSurface = try #require(CVPixelBufferGetIOSurface(initial)?.takeUnretainedValue())
        #expect((first.layer?.sublayers?.first?.contents as AnyObject?) === initialSurface)
        #expect((second.layer?.sublayers?.first?.contents as AnyObject?) === initialSurface)
        VirtualCameraPreview.dismantleNSView(first, coordinator: ())
        let next = try #require(VirtualCameraFixtures.quadrants())
        display.push(next)
        display.flush()
        let nextSurface = try #require(CVPixelBufferGetIOSurface(next)?.takeUnretainedValue())
        #expect(first.layer?.sublayers?.first?.contents == nil)
        #expect((second.layer?.sublayers?.first?.contents as AnyObject?) === nextSurface)
        display.attach(first)
        #expect((first.layer?.sublayers?.first?.contents as AnyObject?) === nextSurface)
        display.clear()
        #expect(first.layer?.sublayers?.first?.contents == nil)
        #expect(second.layer?.sublayers?.first?.contents == nil)
    }

    @Test func anchorsAreNormalizedFromTheTopLeft() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        #expect(
            VirtualCameraPreviewNSView.anchor(of: CGPoint(x: 10, y: 120), in: rect, mirrored: false)
                == CGPoint(x: 0, y: 0))
        #expect(
            VirtualCameraPreviewNSView.anchor(of: CGPoint(x: 210, y: 20), in: rect, mirrored: false)
                == CGPoint(x: 1, y: 1))
        #expect(
            VirtualCameraPreviewNSView.anchor(of: CGPoint(x: 60, y: 70), in: rect, mirrored: true)
                == CGPoint(x: 0.75, y: 0.5))
        #expect(
            VirtualCameraPreviewNSView.anchor(
                of: CGPoint(x: -50, y: 900), in: rect, mirrored: false)
                == CGPoint(x: 0, y: 0))
        #expect(
            VirtualCameraPreviewNSView.anchor(of: .zero, in: .zero, mirrored: false)
                == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func scrollingUpZoomsIn() {
        #expect(VirtualCameraPreviewNSView.zoomFactor(scrollDelta: 10, precise: true) > 1)
        #expect(VirtualCameraPreviewNSView.zoomFactor(scrollDelta: -10, precise: true) < 1)
        #expect(
            VirtualCameraPreviewNSView.zoomFactor(scrollDelta: 1, precise: false)
                > VirtualCameraPreviewNSView.zoomFactor(scrollDelta: 1, precise: true))
    }

    @Test func thePictureKeepsItsAspectInsideTheView() {
        let view = VirtualCameraPreviewNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(view.pictureRect == CGRect(x: 0, y: 87.5, width: 400, height: 225))
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 225)
        #expect(view.pictureRect == CGRect(x: 300, y: 0, width: 400, height: 225))
    }

    @Test func draggingReportsPointerDeltas() throws {
        let view = VirtualCameraPreviewNSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        var deltas: [CGSize] = []
        var resets = 0
        view.onPan = { delta, size in
            deltas.append(delta)
            #expect(size == CGSize(width: 320, height: 180))
        }
        view.onReset = { resets += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks,
                    pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 130, y: 90)))
        #expect(deltas == [CGSize(width: 30, height: 10)])
        view.mirrored = true
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 140, y: 90)))
        #expect(deltas.last == CGSize(width: -10, height: 0))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 140, y: 90)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 200, y: 90)))
        #expect(deltas.count == 2)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 50, y: 50), clicks: 2))
        #expect(resets == 1)
    }
}

enum VirtualCameraSyntheticStudio {
    static let size = CGSize(width: 1920, height: 1080)

    static func context() -> CGContext? {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1)
        -> CGColor
    {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func person(in context: CGContext, fill: CGColor?) {
        let skin = fill ?? color(0.86, 0.68, 0.56)
        let sweater = fill ?? color(0.16, 0.25, 0.42)
        let hair = fill ?? color(0.2, 0.13, 0.09)
        context.setFillColor(sweater)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 610, y: -120, width: 700, height: 420), cornerWidth: 190,
                cornerHeight: 190, transform: nil))
        context.fillPath()
        context.setFillColor(skin)
        context.fill(CGRect(x: 910, y: 250, width: 100, height: 110))
        context.fillEllipse(in: CGRect(x: 820, y: 330, width: 280, height: 350))
        context.setFillColor(hair)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 805, y: 560, width: 310, height: 150), cornerWidth: 120,
                cornerHeight: 70, transform: nil))
        context.fillPath()
        guard fill == nil else { return }
        context.setFillColor(color(0.18, 0.12, 0.1))
        context.fillEllipse(in: CGRect(x: 895, y: 500, width: 28, height: 20))
        context.fillEllipse(in: CGRect(x: 997, y: 500, width: 28, height: 20))
        context.setStrokeColor(color(0.55, 0.3, 0.3))
        context.setLineWidth(8)
        context.addArc(
            center: CGPoint(x: 960, y: 450), radius: 45, startAngle: .pi * 1.15,
            endAngle: .pi * 1.85, clockwise: false)
        context.strokePath()
    }

    static func frame() -> CGImage? {
        guard let context = context() else { return nil }
        let wall = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(0.93, 0.87, 0.78), color(0.72, 0.64, 0.55)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(
            wall, start: CGPoint(x: 0, y: 1080), end: CGPoint(x: 1920, y: 0), options: [])
        context.setFillColor(color(0.45, 0.3, 0.2))
        context.fill(CGRect(x: 1320, y: 180, width: 460, height: 760))
        let books: [CGColor] = [
            color(0.75, 0.2, 0.2), color(0.2, 0.45, 0.6), color(0.9, 0.7, 0.2),
            color(0.3, 0.55, 0.35), color(0.55, 0.35, 0.6),
        ]
        for shelf in 0..<3 {
            let y = 220 + CGFloat(shelf) * 240
            context.setFillColor(color(0.32, 0.2, 0.13))
            context.fill(CGRect(x: 1330, y: y - 12, width: 440, height: 12))
            for index in 0..<9 {
                context.setFillColor(books[(index + shelf) % books.count])
                context.fill(
                    CGRect(
                        x: 1345 + CGFloat(index) * 46, y: y,
                        width: 38, height: 150 + CGFloat((index * 37 + shelf * 11) % 50)))
            }
        }
        context.setFillColor(color(0.78, 0.88, 0.96))
        context.fill(CGRect(x: 160, y: 420, width: 420, height: 480))
        context.setStrokeColor(color(1, 1, 1))
        context.setLineWidth(18)
        context.stroke(CGRect(x: 160, y: 420, width: 420, height: 480))
        context.setFillColor(color(0.95, 0.85, 0.5, 0.9))
        context.fillEllipse(in: CGRect(x: 250, y: 240, width: 160, height: 120))
        person(in: context, fill: nil)
        return context.makeImage()
    }

    static func logo() -> CGImage? {
        let size = CGSize(width: 420, height: 120)
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(color(0.04, 0.52, 1))
        context.addPath(
            CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 28, cornerHeight: 28,
                transform: nil))
        context.fillPath()
        context.setFillColor(color(1, 1, 1))
        context.fillEllipse(in: CGRect(x: 26, y: 26, width: 68, height: 68))
        context.setFillColor(color(0.04, 0.52, 1))
        context.fillEllipse(in: CGRect(x: 44, y: 44, width: 32, height: 32))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 58, nil)
        let text = NSAttributedString(
            string: "Studio",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(1, 1, 1),
            ])
        context.textPosition = CGPoint(x: 118, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    static func mask() -> CIImage? {
        guard let context = context() else { return nil }
        context.setFillColor(color(0, 0, 0))
        context.fill(CGRect(origin: .zero, size: size))
        person(in: context, fill: color(1, 1, 1))
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    static func buffer() -> CVPixelBuffer? {
        guard let image = frame(),
            let buffer = VirtualCameraPlaceholder.makeBuffer(
                width: Int(size.width), height: Int(size.height))
        else { return nil }
        VirtualCameraFixtures.context.render(
            CIImage(cgImage: image), to: buffer, bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}

@MainActor
@Suite(.serialized) struct VirtualCameraEvidenceTests {
    nonisolated static let directory =
        ProcessInfo.processInfo.environment["EDITH_VIRTUAL_CAMERA_EVIDENCE_DIR"]

    @Test func syntheticStudioAndMaskAreDistinct() throws {
        let frame = try #require(VirtualCameraSyntheticStudio.frame())
        #expect(frame.width == 1920)
        let mask = try #require(VirtualCameraSyntheticStudio.mask())
        #expect(mask.extent.size == VirtualCameraSyntheticStudio.size)
    }

    @Test(.enabled(if: directory != nil))
    func renderEvidence() async throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = VirtualCameraRenderer()
        let studio = CIImage(cgImage: try #require(VirtualCameraSyntheticStudio.frame()))
        let mask = VirtualCameraSyntheticStudio.mask()
        let size = CGSize(width: 1280, height: 720)
        let logo = VirtualCameraSyntheticStudio.logo()
        func write(_ image: CIImage, _ name: String) throws {
            let cgImage = try #require(renderer.cgImage(image, size: size))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name))
        }

        var closeUp = VirtualCameraComposition(
            framing: VirtualCameraFraming(zoom: 1.7, centerX: 0.5, centerY: 0.44),
            look: VirtualCameraLook(preset: .studio, warmth: 0.1, vignette: 0.25),
            background: VirtualCameraBackground(mode: .blur, blur: 0.8),
            overlays: VirtualCameraOverlays(
                nameTag: VirtualCameraNameTag(
                    enabled: true, title: "Ada Lovelace", subtitle: "Staff Engineer",
                    style: .bar, corner: .bottomLeft)))
        try write(
            renderer.compose(
                VirtualCameraFrameInput(image: studio, composition: VirtualCameraComposition()),
                output: size), "output-raw.png")
        try write(
            renderer.compose(
                VirtualCameraFrameInput(image: studio, composition: closeUp, mask: mask),
                output: size), "output-close-up.png")
        closeUp.background = VirtualCameraBackground(
            mode: .color, color: VirtualCameraColor(hex: "#1E293B") ?? .black)
        closeUp.look = VirtualCameraLook(preset: .noir)
        closeUp.overlays.nameTag.style = .pill
        closeUp.overlays.border = VirtualCameraBorder(
            enabled: true, width: 0.006, cornerRadius: 0.06, inset: 0.05)
        closeUp.overlays.clock = VirtualCameraClock(
            enabled: true, corner: .topRight, twentyFourHour: true)
        try write(
            renderer.compose(
                VirtualCameraFrameInput(
                    image: studio, composition: closeUp, mask: mask,
                    date: Date(timeIntervalSince1970: 1_790_000_000)),
                output: size), "output-studio-frame.png")
        var branded = VirtualCameraComposition(
            framing: VirtualCameraFraming(zoom: 1.25, centerX: 0.55, centerY: 0.48, tilt: -2),
            look: VirtualCameraLook(preset: .warm))
        branded.overlays.logo = VirtualCameraLogo(
            enabled: true, imagePath: "/synthetic/logo.png", corner: .topLeft, size: 0.08)
        try write(
            renderer.compose(
                VirtualCameraFrameInput(
                    image: studio, composition: branded,
                    assets: VirtualCameraAssets(logo: logo.map { CIImage(cgImage: $0) })),
                output: size), "output-branded.png")
        let backdrop = renderer.compose(
            VirtualCameraFrameInput(image: studio, composition: VirtualCameraComposition()),
            output: size)
        try write(
            renderer.privacyImage(
                .card, message: "Back in 5 minutes", backdrop: backdrop, output: size),
            "output-pause-card.png")
        let offline = try #require(VirtualCameraPlaceholder.makeBuffer(width: 1280, height: 720))
        VirtualCameraPlaceholder.render(VirtualCameraPlaceholder.card(for: .offline), into: offline)
        try write(CIImage(cvPixelBuffer: offline), "extension-offline.png")

        let name = "test.edith.virtual-camera-evidence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = VirtualCameraPageModel(
            defaults: defaults,
            pipeline: VirtualCameraPipeline(state: VirtualCameraState(), outputSize: size),
            extensionManager: VirtualCameraExtensionManager(
                environment: VirtualCameraExtensionEnvironment(
                    bundleURL: URL(fileURLWithPath: "/Applications/Edith.app"),
                    hasInstallEntitlement: { true }, deviceVisible: { true })),
            accessProvider: { .denied },
            sourceProvider: { VirtualCameraPageModelTests.sources })
        var state = model.state
        state.composition = VirtualCameraComposition(
            framing: VirtualCameraFraming(zoom: 1.7, centerX: 0.5, centerY: 0.44),
            look: VirtualCameraLook(preset: .studio, warmth: 0.1, vignette: 0.25),
            background: VirtualCameraBackground(mode: .blur, blur: 0.8),
            overlays: VirtualCameraOverlays(
                nameTag: VirtualCameraNameTag(
                    enabled: true, title: "Ada Lovelace", subtitle: "Staff Engineer")))
        _ = try? VirtualCameraSceneLibrary.save("Interview", in: &state)
        model.update { $0 = state }
        model.flushSave()
        model.extensionManager.refresh()
        let reference = try #require(
            renderer.cgImage(
                renderer.framedReference(
                    VirtualCameraFrameInput(
                        image: studio, composition: model.composition, mask: mask),
                    output: VirtualCameraPipeline.referenceSize),
                size: VirtualCameraPipeline.referenceSize))
        model.updateLookThumbnails(from: reference)
        await model.waitForLookThumbnails()
        model.injectForTesting(
            snapshot: VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: true, route: .edithCamera,
                extensionBuild: "288",
                clients: [VirtualCameraClient(id: "us.zoom.xos", name: "zoom.us")], live: true,
                framesPerSecond: 30, source: VirtualCameraPageModelTests.sources[0],
                sourceWidth: 1920, sourceHeight: 1080, sources: VirtualCameraPageModelTests.sources,
                format: .hd1080, cameraAccess: "granted", state: model.state),
            sources: VirtualCameraPageModelTests.sources)
        let preview = renderer.compose(
            VirtualCameraFrameInput(image: studio, composition: model.composition, mask: mask),
            output: size)
        let buffer = try #require(VirtualCameraPlaceholder.makeBuffer(width: 1280, height: 720))
        renderer.render(preview, into: buffer)
        model.showPreviewFrame(buffer)
        model.update {
            $0.audio.enabled = true
            $0.audio.clips = [
                MeetingAudioClip(name: "Good morning", path: "/tmp/demo-greeting.wav"),
                MeetingAudioClip(name: "Thunder", path: "/tmp/demo-thunder.wav", speech: false),
            ]
        }
        model.flushSave()
        var meetingSnapshot = try #require(model.snapshot)
        var audioStatus = MeetingAudioStatus()
        audioStatus.running = true
        meetingSnapshot.audioStatus = audioStatus
        meetingSnapshot.state = model.state
        model.injectForTesting(
            snapshot: meetingSnapshot, sources: VirtualCameraPageModelTests.sources)
        for tab in [
            VirtualCameraInspectorTab.frame, .look, .background, .overlays, .output, .audio,
        ] {
            for section in VirtualCameraInspectorTab.allCases {
                model.setInspectorExpanded(section, section == tab)
            }
            try renderPage(
                model, preview: preview, renderer: renderer,
                to: output.appendingPathComponent("page-\(tab.rawValue).png"))
        }
        let previousZoom = UIScale.current
        defer { UIScale.apply(previousZoom) }
        for dark in [true, false] {
            for (label, size, compact, zoom, controls) in [
                ("meeting", CGSize(width: 1440, height: 900), false, 1.0, false),
                ("audio", CGSize(width: 1440, height: 900), false, 1.0, true),
                ("voice", CGSize(width: 1440, height: 1000), false, 1.0, true),
                ("compact", CGSize(width: 620, height: 720), true, 1.0, false),
                ("zoom", CGSize(width: 1440, height: 1000), false, 1.3, true),
            ] {
                UIScale.apply(zoom)
                for section in VirtualCameraInspectorTab.allCases {
                    model.setInspectorExpanded(
                        section,
                        label == "voice" ? [.voice, .devices].contains(section) : section == .audio)
                }
                try renderPage(
                    model, preview: preview, renderer: renderer,
                    to: output.appendingPathComponent("ux-\(label)-\(dark ? "dark" : "light").png"),
                    size: size, compact: compact, dark: dark, controlsVisible: controls)
            }
        }
        UIScale.apply(previousZoom)
        model.updateComposition {
            $0.background = VirtualCameraBackground(
                mode: .color, color: VirtualCameraColor(hex: "#1E293B") ?? .black)
        }
        model.flushSave()
        var snapshot = try #require(model.snapshot)
        snapshot.systemBackgroundActive = true
        snapshot.state = model.state
        model.injectForTesting(snapshot: snapshot, sources: VirtualCameraPageModelTests.sources)
        let nativePreview = renderer.compose(
            VirtualCameraFrameInput(
                image: studio, composition: model.composition, mask: mask,
                systemBackgroundActive: true), output: size)
        renderer.render(nativePreview, into: buffer)
        model.showPreviewFrame(buffer)
        model.tab = .background
        try renderPage(
            model, preview: nativePreview, renderer: renderer,
            to: output.appendingPathComponent("page-system-background.png"))
        model.pause(.stopped)
        snapshot.state = model.state
        snapshot.live = false
        snapshot.framesPerSecond = 0
        snapshot.systemBackgroundActive = false
        snapshot.clients = []
        model.injectForTesting(snapshot: snapshot, sources: VirtualCameraPageModelTests.sources)
        model.tab = .output
        try renderPage(
            model, preview: nativePreview, renderer: renderer,
            to: output.appendingPathComponent("page-stopped.png"))
    }

    private func renderPage(
        _ model: VirtualCameraPageModel, preview: CIImage, renderer: VirtualCameraRenderer,
        to url: URL, size: CGSize = CGSize(width: 1440, height: 1060),
        compact: Bool = false, dark: Bool = true, controlsVisible: Bool = true
    ) throws {
        let host = NSHostingView(
            rootView: VirtualCameraPage(model: model, controlsVisible: controlsVisible)
                .environment(\.compactLayout, compact)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.windowVisible, false)
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.animation = nil })
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = host.appearance
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        var overlay: NSImageView?
        if model.state.privacy != .stopped {
            let previewView = try #require(Self.find(VirtualCameraPreviewNSView.self, in: host))
            let container = try #require(previewView.superview)
            let image = try #require(
                renderer.cgImage(preview, size: CGSize(width: 1280, height: 720)))
            let frame = previewView.convert(previewView.pictureRect, to: container)
            let imageView = NSImageView(frame: frame)
            imageView.image = NSImage(cgImage: image, size: frame.size)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 14
            imageView.layer?.masksToBounds = true
            container.addSubview(imageView, positioned: .above, relativeTo: previewView)
            overlay = imageView
        }
        defer { overlay?.removeFromSuperview() }
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
