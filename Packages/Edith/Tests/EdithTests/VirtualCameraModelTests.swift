import Foundation
import Testing

@testable import EdithKit

@Suite struct VirtualCameraModelTests {
    @Test func colorsParseAndPrintHex() throws {
        let opaque = try #require(VirtualCameraColor(hex: "#0A84FF"))
        #expect(opaque.hex == "#0A84FF")
        #expect(abs(opaque.blue - 1) < 0.0001)
        let translucent = try #require(VirtualCameraColor(hex: "11223380"))
        #expect(translucent.hex == "#11223380")
        #expect(abs(translucent.alpha - 128.0 / 255.0) < 0.0001)
        #expect(VirtualCameraColor(hex: "#12345") == nil)
        #expect(VirtualCameraColor(hex: "#GG0000") == nil)
        #expect(VirtualCameraColor(red: 2, green: -1, blue: .nan).hex == "#FF0000")
        #expect(VirtualCameraColor.white.luminance > VirtualCameraColor.black.luminance)
    }

    @Test func colorsEncodeAsHexStrings() throws {
        let data = try JSONEncoder().encode([VirtualCameraColor.accent])
        #expect(String(decoding: data, as: UTF8.self) == "[\"#0A84FF\"]")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([VirtualCameraColor].self, from: Data("[\"blue\"]".utf8))
        }
    }

    @Test func emptyCompositionDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(
            VirtualCameraComposition.self, from: Data("{}".utf8))
        #expect(decoded == VirtualCameraComposition())
        #expect(decoded.framing.isIdentity)
        #expect(decoded.look.isNeutral)
        #expect(decoded.overlays.activeCount == 0)
    }

    @Test func outOfRangeValuesAreClampedWhileDecoding() throws {
        let json = """
            {"framing":{"zoom":50,"centerX":-3,"centerY":0.25,"tilt":90,"quarterTurns":-1,
            "autoFrame":"sideways"},
            "look":{"preset":"sepia","exposure":9,"contrast":0.1,"saturation":5,"warmth":-4,
            "vignette":2},
            "background":{"mode":"blur","blur":7,"imagePath":""},
            "overlays":{"logo":{"enabled":true,"size":3,"opacity":-1},
            "border":{"enabled":true,"width":1,"cornerRadius":-2,"inset":0.5},
            "nameTag":{"enabled":true,"title":"\(String(repeating: "x", count: 90))"}}}
            """
        let decoded = try JSONDecoder().decode(VirtualCameraComposition.self, from: Data(json.utf8))
        #expect(decoded.framing.zoom == 8)
        #expect(decoded.framing.centerX == 0)
        #expect(decoded.framing.centerY == 0.25)
        #expect(decoded.framing.tilt == 45)
        #expect(decoded.framing.quarterTurns == 3)
        #expect(decoded.framing.autoFrame == .off)
        #expect(decoded.look.preset == .natural)
        #expect(decoded.look.exposure == 2)
        #expect(decoded.look.contrast == 0.5)
        #expect(decoded.look.saturation == 2)
        #expect(decoded.look.warmth == -1)
        #expect(decoded.look.vignette == 1)
        #expect(decoded.background.mode == .blur)
        #expect(decoded.background.blur == 1)
        #expect(decoded.background.imagePath == nil)
        #expect(decoded.overlays.logo.size == VirtualCameraLogo.sizeRange.upperBound)
        #expect(decoded.overlays.logo.opacity == 0)
        #expect(!decoded.overlays.logo.isVisible)
        #expect(decoded.overlays.border.width == VirtualCameraBorder.widthRange.upperBound)
        #expect(decoded.overlays.border.cornerRadius == 0)
        #expect(decoded.overlays.border.inset == VirtualCameraBorder.insetRange.upperBound)
        #expect(decoded.overlays.nameTag.title.count == VirtualCameraNameTag.maximumLength)
    }

    @Test func nonFiniteValuesFallBackToDefaults() {
        var framing = VirtualCameraFraming(zoom: .nan, centerX: .infinity, tilt: -.infinity)
        framing = framing.sanitized()
        #expect(framing.zoom == 1)
        #expect(framing.centerX == 0.5)
        #expect(framing.tilt == 0)
        var look = VirtualCameraLook(exposure: .nan, contrast: .infinity)
        look = look.sanitized()
        #expect(look.exposure == 0)
        #expect(look.contrast == 1)
    }

    @Test func compositionRoundTripsThroughJSON() throws {
        let composition = VirtualCameraComposition(
            framing: VirtualCameraFraming(
                zoom: 2.5, centerX: 0.4, centerY: 0.35, tilt: -3, quarterTurns: 1,
                flipHorizontal: true, autoFrame: .medium),
            look: VirtualCameraLook(preset: .film, intensity: 0.6, exposure: 0.3, warmth: 0.2),
            background: VirtualCameraBackground(
                mode: .color, color: VirtualCameraColor(hex: "#112233") ?? .black),
            overlays: VirtualCameraOverlays(
                nameTag: VirtualCameraNameTag(
                    enabled: true, title: "Ada Lovelace", subtitle: "Engineer", style: .pill,
                    corner: .bottomRight),
                clock: VirtualCameraClock(enabled: true, corner: .topRight, twentyFourHour: true),
                border: VirtualCameraBorder(enabled: true)))
        let data = try JSONEncoder().encode(composition)
        let decoded = try JSONDecoder().decode(VirtualCameraComposition.self, from: data)
        #expect(decoded == composition)
        #expect(decoded.overlays.activeCount == 3)
        #expect(!decoded.look.isNeutral)
        #expect(!decoded.framing.isIdentity)
    }

    @Test func backgroundModesNeedSegmentationOnlyWhenTheyReplaceSomething() {
        #expect(!VirtualCameraBackground(mode: .none).needsSegmentation)
        #expect(VirtualCameraBackground(mode: .blur).needsSegmentation)
        #expect(VirtualCameraBackground(mode: .color).needsSegmentation)
        #expect(!VirtualCameraBackground(mode: .image).needsSegmentation)
        #expect(VirtualCameraBackground(mode: .image, imagePath: "/tmp/b.png").needsSegmentation)
    }

    @Test func nameTagsNeedEnabledText() {
        #expect(!VirtualCameraNameTag(enabled: true, title: "  ").isVisible)
        #expect(!VirtualCameraNameTag(enabled: false, title: "Ada").isVisible)
        #expect(VirtualCameraNameTag(enabled: true, subtitle: "Host").isVisible)
    }

    @Test func clockTextFollowsTheChosenStyle() throws {
        let zone = try #require(TimeZone(identifier: "UTC"))
        let morning = Date(timeIntervalSince1970: 9 * 3600 + 5 * 60 + 7)
        let evening = Date(timeIntervalSince1970: 21 * 3600 + 45 * 60)
        let midnight = Date(timeIntervalSince1970: 0)
        #expect(VirtualCameraClock().text(for: morning, timeZone: zone) == "9:05 AM")
        #expect(VirtualCameraClock().text(for: evening, timeZone: zone) == "9:45 PM")
        #expect(VirtualCameraClock().text(for: midnight, timeZone: zone) == "12:00 AM")
        #expect(
            VirtualCameraClock(twentyFourHour: true).text(for: evening, timeZone: zone) == "21:45")
        #expect(
            VirtualCameraClock(showsSeconds: true, twentyFourHour: true)
                .text(for: morning, timeZone: zone) == "09:05:07")
    }

    @Test func stateSanitizingDropsBrokenScenes() {
        let id = UUID()
        let state = VirtualCameraState(
            sourceID: "",
            scenes: [
                VirtualCameraScene(id: id, name: " Desk ", composition: VirtualCameraComposition()),
                VirtualCameraScene(id: id, name: "Copy", composition: VirtualCameraComposition()),
                VirtualCameraScene(name: "desk", composition: VirtualCameraComposition()),
                VirtualCameraScene(name: "   ", composition: VirtualCameraComposition()),
                VirtualCameraScene(name: "Wide", composition: VirtualCameraComposition()),
            ],
            activeSceneID: UUID(), privacyMessage: "   "
        ).sanitized()
        #expect(state.scenes.map(\.name) == ["Desk", "Wide"])
        #expect(state.activeSceneID == nil)
        #expect(state.sourceID == nil)
        #expect(state.privacyMessage == VirtualCameraState.defaultPrivacyMessage)
    }

    @Test func stateCapsScenesAndMessages() {
        let scenes = (0..<40).map {
            VirtualCameraScene(name: "Scene \($0)", composition: VirtualCameraComposition())
        }
        let state = VirtualCameraState(
            scenes: scenes, privacyMessage: String(repeating: "a", count: 200)
        ).sanitized()
        #expect(state.scenes.count == VirtualCameraState.maximumScenes)
        #expect(state.privacyMessage.count == VirtualCameraState.maximumMessageLength)
    }

    @Test func legacyStateDecodesWithStarterScenes() throws {
        let decoded = try JSONDecoder().decode(
            VirtualCameraState.self, from: Data("{\"privacy\":\"card\"}".utf8))
        #expect(decoded.privacy == .card)
        #expect(decoded.scenes.map(\.name) == ["Full frame", "Close-up"])
        #expect(decoded.transition == .smooth)
        #expect(decoded.sharpZoom)
        #expect(decoded.mirrorPreview)
        let garbage = try JSONDecoder().decode(
            VirtualCameraState.self, from: Data("{\"privacy\":\"loud\",\"scenes\":7}".utf8))
        #expect(garbage.privacy == .live)
        #expect(garbage.scenes.count == 2)
    }

    @Test func privacyAndTransitionDescribeThemselves() {
        #expect(VirtualCameraPrivacy.live.usesCamera)
        #expect(!VirtualCameraPrivacy.card.usesCamera)
        #expect(!VirtualCameraPrivacy.freeze.usesCamera)
        #expect(VirtualCameraTransition.cut.duration == 0)
        #expect(VirtualCameraTransition.smooth.duration > 0)
        #expect(Set(VirtualCameraLookPreset.allCases.map(\.title)).count == 10)
    }
}

@Suite struct VirtualCameraSceneLibraryTests {
    func state() -> VirtualCameraState {
        VirtualCameraState(
            scenes: [
                VirtualCameraScene(name: "Desk", composition: VirtualCameraComposition()),
                VirtualCameraScene(
                    name: "Close-up",
                    composition: VirtualCameraComposition(
                        framing: VirtualCameraFraming(zoom: 2)), sourceID: "cam-b"),
                VirtualCameraScene(name: "Whiteboard", composition: VirtualCameraComposition()),
            ])
    }

    @Test func findMatchesIdNameNumberAndUniquePrefix() {
        let scenes = state().scenes
        #expect(VirtualCameraSceneLibrary.find("close-UP", in: scenes)?.name == "Close-up")
        #expect(VirtualCameraSceneLibrary.find("3", in: scenes)?.name == "Whiteboard")
        #expect(VirtualCameraSceneLibrary.find("white", in: scenes)?.name == "Whiteboard")
        #expect(VirtualCameraSceneLibrary.find(scenes[0].id.uuidString, in: scenes)?.name == "Desk")
        #expect(VirtualCameraSceneLibrary.find("9", in: scenes) == nil)
        #expect(VirtualCameraSceneLibrary.find("", in: scenes) == nil)
        let ambiguous =
            scenes + [
                VirtualCameraScene(name: "Deskside", composition: VirtualCameraComposition())
            ]
        #expect(VirtualCameraSceneLibrary.find("des", in: ambiguous) == nil)
        #expect(VirtualCameraSceneLibrary.find("desk", in: ambiguous)?.name == "Desk")
    }

    @Test func applyLoadsTheSceneAndItsCamera() throws {
        var value = state()
        let scene = try VirtualCameraSceneLibrary.apply("Close-up", in: &value)
        #expect(value.composition.framing.zoom == 2)
        #expect(value.sourceID == "cam-b")
        #expect(value.activeSceneID == scene.id)
        #expect(!value.activeSceneIsModified)
        value.composition.framing.zoom = 3
        #expect(value.activeSceneIsModified)
        #expect(throws: VirtualCameraSceneError.notFound("Nope")) {
            try VirtualCameraSceneLibrary.apply("Nope", in: &value)
        }
    }

    @Test func saveRejectsDuplicatesUnlessReplacing() throws {
        var value = state()
        value.composition.framing.zoom = 4
        let saved = try VirtualCameraSceneLibrary.save("Podcast", in: &value)
        #expect(value.scenes.last == saved)
        #expect(value.activeSceneID == saved.id)
        #expect(throws: VirtualCameraSceneError.duplicateName("desk")) {
            try VirtualCameraSceneLibrary.save("desk", in: &value)
        }
        let replaced = try VirtualCameraSceneLibrary.save("desk", in: &value, replacing: true)
        #expect(replaced.name == "Desk")
        #expect(replaced.composition.framing.zoom == 4)
        #expect(value.scenes.count == 4)
        #expect(throws: VirtualCameraSceneError.emptyName) {
            try VirtualCameraSceneLibrary.save("   ", in: &value)
        }
    }

    @Test func saveStopsAtTheSceneLimit() {
        var value = VirtualCameraState(
            scenes: (0..<VirtualCameraState.maximumScenes).map {
                VirtualCameraScene(name: "S\($0)", composition: VirtualCameraComposition())
            })
        #expect(throws: VirtualCameraSceneError.limitReached(VirtualCameraState.maximumScenes)) {
            try VirtualCameraSceneLibrary.save("One more", in: &value)
        }
    }

    @Test func renameDuplicateDeleteAndMove() throws {
        var value = state()
        let desk = value.scenes[0].id
        try VirtualCameraSceneLibrary.rename(desk, to: "Standing desk", in: &value)
        #expect(value.scenes[0].name == "Standing desk")
        #expect(throws: VirtualCameraSceneError.duplicateName("Whiteboard")) {
            try VirtualCameraSceneLibrary.rename(desk, to: "Whiteboard", in: &value)
        }
        let copy = try VirtualCameraSceneLibrary.duplicate(desk, in: &value)
        #expect(copy.name == "Standing desk 2")
        #expect(value.scenes[1].id == copy.id)
        _ = try VirtualCameraSceneLibrary.apply(copy.name, in: &value)
        try VirtualCameraSceneLibrary.delete(copy.id, in: &value)
        #expect(value.activeSceneID == nil)
        #expect(!value.scenes.contains { $0.id == copy.id })
        VirtualCameraSceneLibrary.move(desk, by: 5, in: &value)
        #expect(value.scenes.last?.id == desk)
        VirtualCameraSceneLibrary.move(desk, by: -10, in: &value)
        #expect(value.scenes.first?.id == desk)
    }

    @Test func updateStoresTheCurrentComposition() throws {
        var value = state()
        let whiteboard = value.scenes[2].id
        value.composition.look.preset = .noir
        value.sourceID = "cam-c"
        try VirtualCameraSceneLibrary.update(whiteboard, in: &value)
        #expect(value.scenes[2].composition.look.preset == .noir)
        #expect(value.scenes[2].sourceID == "cam-c")
        #expect(value.activeSceneID == whiteboard)
    }

    @Test func stepWrapsAroundInBothDirections() {
        var value = state()
        var names: [String?] = []
        for offset in [1, 1, 1, 1, -1] {
            names.append(VirtualCameraSceneLibrary.step(offset, in: &value)?.name)
        }
        #expect(names == ["Desk", "Close-up", "Whiteboard", "Desk", "Whiteboard"])
        var empty = VirtualCameraState(scenes: [])
        let none = VirtualCameraSceneLibrary.step(1, in: &empty)
        #expect(none == nil)
    }

    @Test func uniqueNamesCountUpward() {
        let scenes = state().scenes
        #expect(VirtualCameraSceneLibrary.uniqueName("Desk", in: scenes) == "Desk 2")
        #expect(VirtualCameraSceneLibrary.uniqueName("New", in: scenes) == "New")
        #expect(VirtualCameraSceneLibrary.uniqueName("  ", in: scenes) == "Scene")
    }
}
