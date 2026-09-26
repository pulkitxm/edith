import EdithKit
import Foundation
import Testing

@testable import EdithCLI

final class FakeCameraHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var state: VirtualCameraState
    private(set) var requests: [VirtualCameraRequest] = []
    let sources = [
        VirtualCameraSource(id: "cam-built-in", name: "FaceTime HD Camera", kind: .builtIn),
        VirtualCameraSource(id: "cam-desk", name: "Studio Display Camera", kind: .external),
    ]
    var failure: String?

    init(state: VirtualCameraState = VirtualCameraState()) {
        self.state = state
    }

    var current: VirtualCameraState { lock.withLock { state } }

    func reply(to payload: [String: Any]) -> [AnyHashable: Any] {
        guard let runtime = VirtualCameraRuntimeRequest(payload: payload) else {
            return [VirtualCameraIPC.okKey: false, VirtualCameraIPC.errorKey: "bad request"]
        }
        let result: [String: Any] = lock.withLock {
            requests.append(runtime.request)
            if let failure {
                return snapshot(message: nil).resultPayload(
                    requestID: runtime.requestID, error: failure)
            }
            var next = state
            do {
                let message = try VirtualCameraRequestReducer.apply(
                    runtime.request, to: &next, sources: sources, fileExists: { _ in true })
                state = next.sanitized()
                return snapshot(message: runtime.request == .status ? nil : message)
                    .resultPayload(requestID: runtime.requestID)
            } catch {
                return snapshot(message: nil).resultPayload(
                    requestID: runtime.requestID, error: error.localizedDescription)
            }
        }
        return result.reduce(into: [AnyHashable: Any]()) { $0[$1.key] = $1.value }
    }

    private func snapshot(message: String?) -> VirtualCameraSnapshot {
        VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: true, route: .edithCamera,
            extensionBuild: "42",
            clients: [VirtualCameraClient(id: "us.zoom.xos", name: "zoom.us")], live: true,
            framesPerSecond: 30, source: sources[0], sourceWidth: 1920, sourceHeight: 1080,
            sources: sources, format: .hd1080, cameraAccess: "granted", state: state,
            message: message)
    }
}

@Suite struct VirtualCameraCLITests {
    static func connect(_ world: CLIWorld, to helper: FakeCameraHelper) {
        world.helperRunning(true)
        world.answers { name in
            guard name == IPC.Name.virtualCameraActionResult,
                let payload = world.postedPayloads(for: IPC.Name.requestVirtualCameraAction).last
            else { return nil }
            return helper.reply(to: payload)
        }
    }

    @Test func commandsAndAliasesParse() throws {
        let zoom = try EdRoot.parseAsRoot(["camera", "zoom", "2"])
        #expect(CommandCrawler.name(of: type(of: zoom)) == "zoom")
        #expect(try EdRoot.parseAsRoot(["camera"]) is CameraStatusCommand)
        #expect(try EdRoot.parseAsRoot(["camera", "scene"]) is CameraSceneListCommand)
        #expect(try EdRoot.parseAsRoot(["camera", "cameras"]) is CameraSourcesCommand)
        #expect(try EdRoot.parseAsRoot(["camera", "scene", "ls"]) is CameraSceneListCommand)
        #expect(try EdRoot.parseAsRoot(["camera", "scene", "prev"]) is CameraScenePreviousCommand)
    }

    @Test func valueParsersAcceptTheDocumentedWords() throws {
        #expect(try CameraCLI.number("2x", "zoom") == 2)
        #expect(try CameraCLI.autoFrame("MEDIUM") == .medium)
        #expect(try CameraCLI.look("Noir") == .noir)
        #expect(try CameraCLI.background("original") == VirtualCameraBackgroundMode.none)
        #expect(try CameraCLI.pause("freeze") == .freeze)
        #expect(throws: CLIFailure.self) { try CameraCLI.number("big", "zoom") }
        #expect(throws: CLIFailure.self) { try CameraCLI.autoFrame("tight") }
        #expect(throws: CLIFailure.self) { try CameraCLI.look("sepia") }
        #expect(throws: CLIFailure.self) { try CameraCLI.background("green") }
        #expect(throws: CLIFailure.self) { try CameraCLI.pause("live") }
    }

    @Test func statusWorksWithoutTheAppFromStoredState() async {
        await CLIProbe.inWorld { world in
            var state = VirtualCameraState()
            state.composition.framing.zoom = 2.5
            state.privacy = .card
            VirtualCameraStore.save(state, to: world.shared)
            world.shared.set(true, forKey: AppStorageKeys.VirtualCamera.enabled)
            let result = await CLIProbe.capture(["camera", "status", "--json"])
            #expect(result.code == 0)
            #expect(result.object?["enabled"] as? Bool == true)
            #expect(result.object?["helperRunning"] as? Bool == false)
            #expect(result.object?["privacy"] as? String == "card")
            let framing = result.object?["framing"] as? [String: Any]
            #expect(framing?["zoom"] as? Double == 2.5)
            #expect(result.object?["headline"] as? String == "Waiting for Edith")
        }
    }

    @Test func plainStatusPrintsOneFactPerLine() async {
        let result = await CLIProbe.run(["camera"])
        #expect(result.code == 0)
        #expect(result.stdout.contains("state: Off"))
        #expect(result.stdout.contains("zoom: 1.00x"))
        #expect(result.stdout.contains("scene: none"))
    }

    @Test func offlineSceneListShowsTheStarterScenes() async {
        let result = await CLIProbe.run(["camera", "scene", "list", "--json"])
        #expect(result.code == 0)
        let scenes = result.array as? [[String: Any]] ?? []
        #expect(scenes.compactMap { $0["name"] as? String } == ["Full frame", "Close-up"])
        #expect(scenes.first?["number"] as? Int == 1)
    }

    @Test func changesNeedTheMenuBarApp() async {
        let result = await CLIProbe.run(["camera", "zoom", "2"])
        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("menu bar app"))
        #expect(result.stdout.isEmpty)
    }

    @Test func zoomRoundTripsThroughTheHelper() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            let result = await CLIProbe.capture(["camera", "zoom", "1.5x", "--json"])
            #expect(result.code == 0)
            #expect(helper.requests == [.zoom(1.5)])
            #expect(result.object?["message"] as? String == "Zoom set to 1.50x.")
            #expect((result.object?["framing"] as? [String: Any])?["zoom"] as? Double == 1.5)
            let posted = world.postedPayloads(for: IPC.Name.requestVirtualCameraAction)
            #expect(posted.count == 1)
            #expect(
                (posted.first?[VirtualCameraIPC.deadlineKey] as? TimeInterval ?? 0)
                    > Date().timeIntervalSince1970)
        }
    }

    @Test func frameSendsOnlyTheOptionsGiven() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            let result = await CLIProbe.capture([
                "camera", "frame", "--x", "0.4", "--auto", "medium", "--flip", "true",
            ])
            #expect(result.code == 0)
            #expect(
                helper.requests
                    == [
                        .frame(
                            VirtualCameraFrameChange(
                                centerX: 0.4, flipHorizontal: true, autoFrame: .medium))
                    ])
            #expect(result.stdout.contains("Framing updated."))
            #expect(helper.current.composition.framing.autoFrame == .medium)
        }
    }

    @Test func emptyFrameFailsBeforePosting() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            let result = await CLIProbe.capture(["camera", "frame"])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stderr.contains("--zoom"))
            #expect(world.postedPayloads(for: IPC.Name.requestVirtualCameraAction).isEmpty)
        }
    }

    @Test func helperErrorsBecomeFailures() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            let result = await CLIProbe.capture(["camera", "zoom", "12"])
            #expect(result.code == ExitCodes.failure)
            #expect(result.stderr.contains("Zoom must be between 1 and 8"))
        }
    }

    @Test func sourcesListsTheHelpersCameras() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            let plain = await CLIProbe.capture(["camera", "sources"])
            #expect(plain.stdout.contains("* 1. FaceTime HD Camera [builtIn]"))
            #expect(plain.stdout.contains("  2. Studio Display Camera [external]"))
            let selected = await CLIProbe.capture(["camera", "source", "studio", "--json"])
            #expect(selected.code == 0)
            #expect(helper.current.sourceID == "cam-desk")
        }
    }

    @Test func looksBackgroundsAndPausesReachTheHelper() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            #expect(await CLIProbe.capture(["camera", "look", "studio"]).code == 0)
            #expect(
                await CLIProbe.capture([
                    "camera", "background", "color", "--color", "#112233",
                ]).code == 0)
            #expect(
                await CLIProbe.capture([
                    "camera", "pause", "--style", "blank", "--message", "Back soon",
                ]).code == 0)
            let current = helper.current
            #expect(current.composition.look.preset == .studio)
            #expect(current.composition.background.mode == .color)
            #expect(current.composition.background.color.hex == "#112233")
            #expect(current.privacy == .blank)
            #expect(current.privacyMessage == "Back soon")
            #expect(await CLIProbe.capture(["camera", "resume"]).code == 0)
            #expect(helper.current.privacy == .live)
            let invalid = await CLIProbe.capture([
                "camera", "background", "color", "--color", "red",
            ])
            #expect(invalid.code == ExitCodes.failure)
            #expect(invalid.stderr.contains("hex color"))
        }
    }

    @Test func scenesApplySaveAndStep() async {
        await CLIProbe.inWorld { world in
            let helper = FakeCameraHelper()
            Self.connect(world, to: helper)
            let applied = await CLIProbe.capture(["camera", "scene", "apply", "close", "--json"])
            #expect(applied.code == 0)
            #expect(applied.object?["scene"] as? String == "Close-up")
            #expect(await CLIProbe.capture(["camera", "zoom", "3"]).code == 0)
            let saved = await CLIProbe.capture(["camera", "scene", "save", "Podcast"])
            #expect(saved.stdout.contains("Scene Podcast saved."))
            let duplicate = await CLIProbe.capture(["camera", "scene", "save", "podcast"])
            #expect(duplicate.code == ExitCodes.failure)
            #expect(duplicate.stderr.contains("already exists"))
            let replaced = await CLIProbe.capture([
                "camera", "scene", "save", "podcast", "--replace",
            ])
            #expect(replaced.code == 0)
            let next = await CLIProbe.capture(["camera", "scene", "next", "--json"])
            #expect(next.object?["scene"] as? String == "Full frame")
            let previous = await CLIProbe.capture(["camera", "scene", "previous", "--json"])
            #expect(previous.object?["scene"] as? String == "Podcast")
            let missing = await CLIProbe.capture(["camera", "scene", "apply", "Nope"])
            #expect(missing.code == ExitCodes.failure)
        }
    }

    @Test func onAndOffToggleTheExtension() async {
        await CLIProbe.inWorld { world in
            world.shared.set(true, forKey: SuiteRegistry.suite(.media).defaultsKey)
            let on = await CLIProbe.capture(["camera", "on", "--json"])
            #expect(on.code == 0)
            #expect(on.object?["enabled"] as? Bool == true)
            #expect(world.shared.bool(forKey: AppStorageKeys.VirtualCamera.enabled))
            let off = await CLIProbe.capture(["camera", "off"])
            #expect(off.code == 0)
            #expect(off.stdout.contains("virtual camera off"))
            #expect(!world.shared.bool(forKey: AppStorageKeys.VirtualCamera.enabled))
        }
    }

    @Test func silenceNamesTheCauseWhenTheHelperDoesNotAnswer() async {
        await CLIProbe.inWorld { world in
            world.helperRunning(true)
            world.answers { _ in nil }
            let result = await CLIProbe.capture(["camera", "reset"])
            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("extension behind Virtual Camera is off"))
        }
    }
}
