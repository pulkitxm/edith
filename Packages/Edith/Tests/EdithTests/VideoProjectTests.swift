import Foundation
import Testing
@testable import Edith

@Suite struct VideoProjectTests {
    @Test func savesAnOpenScreenProjectWithoutErasingUnknownSettings() throws {
        var project = VideoProject.create(title: "Demo")
        project.root["legacyEditor"] = [
            "wallpaper": "#112233", "cursorTheme": "custom", "motionBlurAmount": 24,
        ]
        project.root["transcripts"] = [["language": "en", "words": ["hello"]]]
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/demo.mov"),
            duration: 6, width: 1920, height: 1080)
        let clipID = try #require(project.clips.first?.id)
        project.split(clipID: clipID, at: 2)
        project.trim(clipID: clipID, start: 0.5, end: 2)
        project.addZoom(startMs: 500, endMs: 1500, depth: 3, x: 0.4, y: 0.6)
        project.addText("Hello", startMs: 1000, endMs: 2500)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-video-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("demo.openscreen")
        try project.save(to: url)
        let reopened = try VideoProject.open(url)

        #expect(reopened.root["schemaVersion"] as? Int == 7)
        #expect(reopened.clips.map(\.duration) == [1.5, 4])
        #expect(reopened.clips[1].timelineStart == 1.5)
        #expect(reopened.zooms.first?.focusX == 0.4)
        #expect(reopened.annotations.first?.text == "Hello")
        #expect(
            (reopened.root["legacyEditor"] as? [String: Any])?["cursorTheme"] as? String == "custom"
        )
        #expect((reopened.root["transcripts"] as? [[String: Any]])?.count == 1)
    }

    @Test func doesNotSplitOutsideClip() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/demo.mov"),
            duration: 2, width: 100, height: 100)
        let id = project.clips[0].id
        project.split(clipID: id, at: -1)
        project.split(clipID: id, at: 2)
        #expect(project.clips.count == 1)
    }

    @Test func buildsAutomaticZoomsFromOpenScreenCursorSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("video.mov")
        let sidecar = URL(fileURLWithPath: video.path + ".cursor.json")
        try Data(
            """
            {"version":2,"samples":[
              {"timeMs":500,"cx":0.2,"cy":0.8,"interactionType":"click"},
              {"timeMs":700,"cx":0.3,"cy":0.7,"interactionType":"click"},
              {"timeMs":2500,"cx":0.6,"cy":0.4,"interactionType":"double-click"}
            ]}
            """.utf8
        ).write(to: sidecar)
        var project = VideoProject.create()
        project.addAsset(video, duration: 4, width: 640, height: 480)
        #expect(project.addAutomaticZooms() == 2)
        #expect(project.zooms.map(\.startMs) == [500, 2500])
        #expect(project.zooms.first?.focusX == 0.2)
        #expect(project.zooms.first?.raw["source"] as? String == "auto")
    }

    @Test func storesEditableOpenScreenTranscriptAndCaptionRegions() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/voice.mov"),
            duration: 4, width: 640, height: 480)
        project.addTranscription(
            assetID: project.assets[0].id,
            words: [
                .init(text: "Hello", start: 0.2, end: 0.6),
                .init(text: "world", start: 0.7, end: 1.2),
            ])
        let transcript = project.root["transcript"] as? [String: Any]
        #expect((transcript?["words"] as? [[String: Any]])?.count == 2)
        #expect(project.annotations.first?.text == "Hello world")
        #expect(project.annotations.first?.raw["annotationSource"] as? String == "auto-caption")
        let wordID = project.transcriptWords[0].id
        project.editTranscriptWord(wordID, text: "Hey")
        #expect(project.transcriptWords[0].text == "Hey")
        #expect(project.annotations.first?.text == "Hey world")
        let updatedTranscript = project.root["transcript"] as? [String: Any]
        let words = updatedTranscript?["words"] as? [[String: Any]] ?? []
        #expect(words[0]["originalText"] as? String == "Hello")
        project.editTranscriptWord(wordID, text: "Hello")
        let restored =
            (project.root["transcript"] as? [String: Any])?["words"]
            as? [[String: Any]] ?? []
        #expect(restored[0]["originalText"] == nil)
        #expect(project.annotations.first?.text == "Hello world")
    }

    @Test func captionStyleAndPlacementPreserveOtherAnnotationSettings() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/clip.mov"),
            duration: 2, width: 640, height: 480)
        project.addText("Hello", startMs: 100, endMs: 1000)
        let id = try #require(project.annotations.first?.id)
        project.setAnnotationStyle(id, key: "backgroundColor", value: "#FF0000")
        project.setAnnotationStyle(id, key: "fontSize", value: 64.0)
        project.setAnnotationPosition(id, axis: "y", value: 50)
        let annotation = try #require(project.annotations.first)
        let style = annotation.raw["style"] as? [String: Any]
        #expect(style?["backgroundColor"] as? String == "#FF0000")
        #expect(style?["fontSize"] as? Double == 64)
        #expect(style?["fontFamily"] as? String == "Helvetica Neue")
        #expect((annotation.raw["position"] as? [String: Double])?["y"] == 50)
    }

    @Test func relinksPortableProjectMediaBesideProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-relink-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("moved.mov")
        try Data().write(to: movie)
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/somewhere-else/moved.mov"),
            duration: 1, width: 100, height: 100)
        let camera = directory.appendingPathComponent("camera.mov")
        try Data().write(to: camera)
        project.attachCamera(
            URL(fileURLWithPath: "/somewhere-else/camera.mov"),
            to: project.assets[0].id, offsetMs: 125)
        project.setCameraVisible(false, for: project.assets[0].id)
        try project.save(to: directory.appendingPathComponent("project.openscreen"))
        project.relinkMediaNextToProject()
        #expect(project.assets[0].url == movie)
        #expect(project.assets[0].cameraTrack?["sourcePath"] as? String == camera.path)
        #expect(project.assets[0].cameraTrack?["offsetMs"] as? Int == 125)
        #expect(project.assets[0].cameraTrack?["visible"] as? Bool == false)
    }

    @Test func zoomMovesWithItsClipWhenClipsAreReordered() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/a.mov"),
            duration: 3, width: 100, height: 100)
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/b.mov"),
            duration: 3, width: 100, height: 100)
        project.addZoom(startMs: 500, endMs: 2000, depth: 3, x: 0.4, y: 0.6)
        #expect(project.zooms.first?.raw["clipId"] as? String == project.clips[0].id)
        project.setClips(Array(project.clips.reversed()))
        #expect(project.zooms.first?.startMs == 3500)
        #expect(project.zooms.first?.endMs == 5000)
    }

    @Test func duplicatingClipCopiesItsAnchoredEditsAndAudio() throws {
        var project = VideoProject.create(title: "Original")
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/a.mov"),
            duration: 3, width: 100, height: 100)
        let original = try #require(project.clips.first?.id)
        project.addZoom(startMs: 500, endMs: 1500, depth: 3, x: 0.4, y: 0.6)
        project.addOverlay(type: "blur", startMs: 1000, endMs: 2000, x: 0.5, y: 0.5)
        project.addAudio(
            URL(fileURLWithPath: "/private/tmp/music.m4a"), duration: 3, at: 0)

        let duplicateID = project.duplicate(clipID: original)
        let duplicate = try #require(duplicateID)
        #expect(project.clips.map(\.id) == [original, duplicate])
        #expect(project.zooms.map(\.startMs) == [500, 3500])
        #expect(project.annotations.map(\.startMs) == [1000, 4000])
        #expect(project.audioTracks.map(\.startMs) == [0, 3000])
        project.setClips(project.clips.filter { $0.id != original })
        #expect(project.zooms.count == 1)
        #expect(project.annotations.count == 1)
        #expect(project.audioTracks.count == 1)
        #expect(project.zooms.first?.startMs == 500)
        project.rename("  Edited  ")
        #expect(project.title == "Edited")
    }

    @Test func transitionsStayWithIncomingClipAndCanBeRemoved() throws {
        var project = VideoProject.create()
        let video = URL(fileURLWithPath: "/private/tmp/transition.mov")
        project.addAsset(video, duration: 2, width: 100, height: 100)
        let first = try #require(project.clips.first?.id)
        let secondID = project.duplicate(clipID: first)
        let second = try #require(secondID)
        project.setTransition(before: first, kind: "fade", duration: 0.8)
        #expect(project.transitions.isEmpty)
        project.setTransition(before: second, kind: "fade", duration: 0.8)
        #expect(project.transitions.first?.clipID == second)
        #expect(project.transitions.first?.duration == 0.8)
        project.setTransition(before: second, kind: "flash", duration: 3)
        #expect(project.transitions.first?.kind == "flash")
        #expect(project.transitions.first?.duration == 2)
        project.setTransition(before: second, kind: "cut", duration: 0.8)
        #expect(project.transitions.isEmpty)
        project.setTransition(before: second, kind: "fade", duration: 0.6)
        project.setClips(project.clips.filter { $0.id != second })
        #expect(project.transitions.isEmpty)
    }

    @Test func editingZoomKeepsItsAnchorAndOtherFields() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/zoom.mov"), duration: 4,
            width: 100, height: 100)
        project.addZoom(startMs: 1000, endMs: 3000, depth: 3, x: 0.5, y: 0.5)
        let id = try #require(project.zooms.first?.id)
        let clipID = project.zooms.first?.raw["clipId"] as? String
        project.updateZoom(id, depth: 5, duration: 1.5, x: 0.2, y: 0.8)
        let zoom = try #require(project.zooms.first)
        #expect(zoom.depth == 5)
        #expect(zoom.startMs == 1000)
        #expect(zoom.endMs == 2500)
        #expect(zoom.focusX == 0.2)
        #expect(zoom.focusY == 0.8)
        #expect(zoom.raw["clipId"] as? String == clipID)
        project.updateZoomTiming(id, startMs: 1500, endMs: 2900)
        let moved = try #require(project.zooms.first)
        #expect(moved.startMs == 1500)
        #expect(moved.endMs == 2900)
        #expect(moved.raw["clipId"] as? String == clipID)
        #expect((moved.raw["sourceStartSec"] as? NSNumber)?.doubleValue == 1.5)
        var legacyZoom = moved.raw
        legacyZoom.removeValue(forKey: "clipId")
        project.root["zoomRanges"] = [legacyZoom]
        project.updateZoomTiming(id, startMs: 1600, endMs: 2800)
        #expect(project.zooms.first?.raw["clipId"] as? String == clipID)
    }

    @Test func skippedSectionsFollowClipsThroughDuplicateSplitAndDelete() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/a.mov"),
            duration: 3, width: 100, height: 100)
        let first = try #require(project.clips.first?.id)
        project.addTrim(clipID: first, start: 1, end: 2)
        let copiedID = project.duplicate(clipID: first)
        let copied = try #require(copiedID)
        #expect(project.trimRanges.count == 2)
        #expect(Set(project.trimRanges.compactMap { $0["clipId"] as? String }) == [first, copied])
        project.split(clipID: first, at: 1.5)
        #expect(project.trimRanges.count == 3)
        #expect(
            project.trimRanges.filter { $0["clipId"] as? String != copied }
                .compactMap { ($0["endSec"] as? NSNumber)?.doubleValue }
                .sorted() == [1.5, 2])
        project.setClips(project.clips.filter { $0.id != copied })
        #expect(project.trimRanges.count == 2)
        let id = try #require(project.trimRanges.first?["id"] as? String)
        project.removeTrim(id)
        #expect(project.trimRanges.count == 1)
    }

    @Test func audioTracksUseOpenScreenAssetAndTrackSchema() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 5, width: 100, height: 100)
        project.addAudio(
            URL(fileURLWithPath: "/private/tmp/music.m4a"),
            duration: 3, at: 1000)
        #expect(project.assets.count == 2)
        #expect(project.assets[1].raw["kind"] as? String == "audio")
        #expect(project.audioTracks[0].startMs == 1000)
        #expect(project.audioTracks[0].endMs == 4000)
        let id = project.audioTracks[0].id
        project.setAudioGain(id, decibels: -6)
        #expect(project.audioTracks[0].gainDb == -6)
        project.setAudioOptions(
            id, muted: true, loop: true,
            fadeInMs: 750, fadeOutMs: 500)
        #expect(project.audioTracks[0].muted)
        #expect(project.audioTracks[0].loop)
        #expect(project.audioTracks[0].raw["fadeInMs"] as? Int == 750)
        project.removeAudioTrack(id)
        #expect(project.audioTracks.isEmpty)
    }

    @Test func microphoneOffsetKeepsNarrationAlignedWithScreen() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/screen.mov"),
            duration: 4, width: 100, height: 100)
        let microphone = URL(fileURLWithPath: "/private/tmp/microphone.m4a")
        project.addAudio(microphone, duration: 4.25, at: 0, sourceOffsetMs: 250)
        #expect(project.audioTracks.count == 1)
        #expect(project.audioTracks[0].offsetMs == 250)
        #expect(project.audioTracks[0].endMs == 4000)

        var late = VideoProject.create()
        late.addAsset(
            URL(fileURLWithPath: "/private/tmp/screen.mov"),
            duration: 4, width: 100, height: 100)
        late.addAudio(microphone, duration: 3.75, at: 250)
        #expect(late.audioTracks[0].startMs == 250)
        #expect(late.audioTracks[0].offsetMs == 0)
    }

    @Test func splittingClipVentilatesItsZoomAndCaption() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 4, width: 100, height: 100)
        project.addZoom(startMs: 1000, endMs: 3000, depth: 3, x: 0.5, y: 0.5)
        project.addText("Across cut", startMs: 1000, endMs: 3000)
        project.split(clipID: project.clips[0].id, at: 2)
        #expect(project.clips.count == 2)
        #expect(project.zooms.map(\.startMs) == [1000, 2000])
        #expect(project.zooms.map(\.endMs) == [2000, 3000])
        #expect(project.zooms[1].raw["clipId"] as? String == project.clips[1].id)
        #expect(project.annotations.count == 2)
    }

    @Test func audioBedAnchorsAcrossMultipleClips() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 2, width: 100, height: 100)
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/other.mov"),
            duration: 2, width: 100, height: 100)
        project.addAudio(
            URL(fileURLWithPath: "/private/tmp/music.caf"),
            duration: 3, at: 500)
        #expect(project.audioTracks.count == 2)
        #expect(project.audioTracks.map(\.offsetMs) == [0, 1500])
        #expect(project.audioTracks[1].raw["clipId"] as? String == project.clips[1].id)
        project.removeAudioTrack(project.audioTracks[0].id)
        #expect(project.audioTracks.isEmpty)
    }

    @Test func speedRegionRemainsAnchoredAfterReordering() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/first.mov"),
            duration: 3, width: 100, height: 100)
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/second.mov"),
            duration: 3, width: 100, height: 100)
        project.addSpeed(startMs: 500, endMs: 1500, rate: 2)
        #expect(project.speedRegions.count == 1)
        #expect(project.speedRegions[0]["clipId"] as? String == project.clips[0].id)
        project.setClips(Array(project.clips.reversed()))
        #expect(project.speedRegions[0]["startMs"] as? Double == 3500)
        project.removeSpeed(project.speedRegions[0]["id"] as? String ?? "")
        #expect(project.speedRegions.isEmpty)
    }

    @Test func trimRemovesOutOfRangeModifiers() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/first.mov"),
            duration: 4, width: 100, height: 100)
        let clipID = project.clips[0].id
        project.addZoom(startMs: 0, endMs: 1000, depth: 2, x: 0.5, y: 0.5)
        project.addText("Removed", startMs: 0, endMs: 1000)
        project.addZoom(startMs: 1500, endMs: 3000, depth: 3, x: 0.5, y: 0.5)
        project.trim(clipID: clipID, start: 2, end: 4)
        #expect(project.zooms.count == 1)
        #expect(project.zooms[0].startMs == 0)
        #expect(project.zooms[0].endMs == 1000)
        #expect(project.annotations.isEmpty)
    }

    @Test func splittingFastClipKeepsOneSpeedFragmentPerSide() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/first.mov"),
            duration: 4, width: 100, height: 100)
        var clips = project.clips
        clips[0].rate = 2
        project.setClips(clips)
        project.split(clipID: project.clips[0].id, at: 2)
        #expect(project.clips.map(\.rate) == [2, 2])
        #expect(project.speedRegions.count == 2)
        #expect(
            project.speedRegions.map { $0["clipId"] as? String }
                == project.clips.map(\.id))
    }

    @Test func cameraTrackPersistsWithSourceAsset() {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 4, width: 100, height: 100)
        let id = project.assets[0].id
        project.attachCamera(
            URL(fileURLWithPath: "/private/tmp/camera.mov"),
            to: id, offsetMs: -120)
        #expect(
            project.assets[0].cameraTrack?["sourcePath"] as? String
                == "/private/tmp/camera.mov")
        #expect(project.assets[0].cameraTrack?["offsetMs"] as? Int == -120)
        project.setCameraVisible(false, for: id)
        #expect(project.assets[0].cameraTrack?["visible"] as? Bool == false)
        project.webcamLayout = "no-webcam"
        #expect(project.webcamLayout == "no-webcam")
        project.webcamPosition = ["cx": 1.5, "cy": 0.2]
        #expect(project.webcamPosition["cx"] == 1)
        project.webcamMaskShape = "circle"
        project.webcamMirrored = true
        project.cursorHighlight = true
        #expect(project.webcamMaskShape == "circle")
        #expect(project.webcamMirrored)
        #expect(project.cursorHighlight)
        project.addCameraFullscreen(startMs: 500, endMs: 1500)
        #expect(project.cameraFullscreenRegions.count == 1)
        #expect(
            project.cameraFullscreenRegions[0]["clipId"] as? String
                == project.clips[0].id)
        project.split(clipID: project.clips[0].id, at: 1)
        #expect(project.cameraFullscreenRegions.count == 2)
        #expect(
            Set(
                project.cameraFullscreenRegions.compactMap {
                    $0["clipId"] as? String
                }) == Set(project.clips.map(\.id)))
        for region in project.cameraFullscreenRegions {
            project.removeCameraFullscreen(region["id"] as? String ?? "")
        }
        #expect(project.cameraFullscreenRegions.isEmpty)
    }

    @Test func migratesV4RegionsToClipAnchors() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 4, width: 1920, height: 1080)
        project.addZoom(startMs: 500, endMs: 1500, depth: 3, x: 0.2, y: 0.8)
        var source = project.root
        source["schemaVersion"] = 4
        var zoom = project.zooms[0].raw
        zoom.removeValue(forKey: "clipId")
        zoom.removeValue(forKey: "sourceStartSec")
        zoom.removeValue(forKey: "sourceEndSec")
        source["zoomRanges"] = [zoom]
        var legacy = source["legacyEditor"] as? [String: Any] ?? [:]
        legacy["aspectRatio"] = "native"
        legacy["speedRegions"] = [
            [
                "id": "old-speed", "startMs": 500,
                "endMs": 1500, "speed": 2,
            ]
        ]
        source["legacyEditor"] = legacy
        let migrated = try VideoProject.migratedDocument(source)
        let loaded = VideoProject(root: migrated, fileURL: nil)
        #expect(migrated["schemaVersion"] as? Int == 7)
        #expect(loaded.zooms[0].raw["clipId"] as? String == loaded.clips[0].id)
        #expect(loaded.zooms[0].raw["sourceStartSec"] as? Double == 0.5)
        #expect(loaded.speedRegions[0]["clipId"] as? String == loaded.clips[0].id)
        #expect(loaded.aspectRatio == "16:9")
    }

    @Test func migratesV6TrimsAcrossDuplicatedClips() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 4, width: 100, height: 100)
        var clips = project.clips
        var second = clips[0]
        second.raw["id"] = "second-clip"
        clips.append(second)
        project.setClips(clips)
        var source = project.root
        source["schemaVersion"] = 6
        var timeline = source["timeline"] as? [String: Any] ?? [:]
        timeline["trimRanges"] = [
            [
                "id": "old-trim", "assetId": project.assets[0].id,
                "startSec": 1, "endSec": 2, "origin": "user", "reason": "",
            ]
        ]
        source["timeline"] = timeline
        let migrated = try VideoProject.migratedDocument(source)
        let trims =
            (migrated["timeline"] as? [String: Any])?["trimRanges"]
            as? [[String: Any]] ?? []
        #expect(trims.count == 2)
        #expect(Set(trims.compactMap { $0["clipId"] as? String }) == Set(clips.map(\.id)))
    }

    @Test func migratesLegacyV2WithoutOverwritingSourceFile() throws {
        let legacy: [String: Any] = [
            "version": 2,
            "media": [
                "screenVideoPath": "/private/tmp/recording.mov",
                "webcamVideoPath": "/private/tmp/camera.mov",
            ],
            "editor": [
                "wallpaper": "#112233",
                "zoomRegions": [
                    [
                        "id": "old-zoom", "startMs": 0, "endMs": 1000,
                        "depth": 2, "focus": ["cx": 0.5, "cy": 0.5],
                    ]
                ],
            ],
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-v2-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("old.openscreen")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: url)
        let migrated = try VideoProject.open(url)
        #expect(migrated.fileURL == nil)
        #expect(migrated.root["schemaVersion"] as? Int == 7)
        #expect(
            migrated.assets[0].cameraTrack?["sourcePath"] as? String
                == "/private/tmp/camera.mov")
        #expect(migrated.zooms.first?.id == "old-zoom")
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func repairsCurrentDocumentsWithoutDroppingUnknownFields() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/private/tmp/video.mov"),
            duration: 3, width: 100, height: 100)
        project.addAudio(
            URL(fileURLWithPath: "/private/tmp/music.caf"),
            duration: 1, at: 0)
        var raw = project.root
        raw["customExtension"] = ["keep": "me"]
        var timeline = raw["timeline"] as? [String: Any] ?? [:]
        timeline["trimRanges"] = [
            [
                "id": "ghost", "assetId": project.audioTracks[0].assetID,
                "startSec": 0, "endSec": 0.5,
            ]
        ]
        raw["timeline"] = timeline
        raw["transcript"] = [
            "assetId": project.assets[0].id,
            "words": [
                [
                    "id": "word", "startSec": 4.0,
                    "endSec": 3.0, "text": "hello",
                ]
            ],
        ]
        let loaded = try VideoProject.migratedDocument(raw)
        #expect((loaded["customExtension"] as? [String: String])?["keep"] == "me")
        #expect(
            ((loaded["timeline"] as? [String: Any])?["trimRanges"]
                as? [[String: Any]])?.isEmpty == true)
        let transcript = loaded["transcript"] as? [String: Any]
        #expect((transcript?["words"] as? [[String: Any]])?[0]["endSec"] as? Double == 4)
    }
}
