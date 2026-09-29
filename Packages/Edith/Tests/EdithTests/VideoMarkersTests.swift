import Foundation
import Testing
@testable import Edith

@Suite struct VideoMarkersTests {
    @Test func markerCRUDAndDocumentRoundTrip() throws {
        var project = VideoProject.create()
        let rate = try VideoMarkerFrameRate(numerator: 30000, denominator: 1001)
        let first = try project.addMarker(atFrame: 120, frameRate: rate, label: "Verse")
        let second = try project.addMarker(atFrame: 30, label: "Click", kind: .transient)
        try project.updateMarker(first.id, frame: 150, label: "Chorus")
        #expect(project.markers.map(\.id) == [second.id, first.id])
        #expect(project.markers.last?.frame == 150)
        #expect(project.markers.last?.frameRate == rate)
        let data = try project.exportMarkers()
        var restored = VideoProject.create()
        try restored.importMarkers(data)
        #expect(restored.markers == project.markers)
        #expect(throws: VideoMarkerError.self) { try restored.importMarkers(data) }
        #expect(restored.markers == project.markers)
        try restored.removeMarker(second.id)
        #expect(restored.markers.count == 1)
        try restored.importMarkers(data, replace: true)
        #expect(restored.markers == project.markers)
        let serialized = try JSONSerialization.data(withJSONObject: restored.root)
        let root = try #require(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
        #expect(VideoProject(root: root).markers == restored.markers)
    }

    @Test func markerPositionsSurviveVideoEdits() throws {
        var project = VideoProject.create()
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/clip.mov"), duration: 12, width: 640, height: 360)
        let clip = try #require(project.clips.first)
        try project.addMarker(atFrame: 90)
        let original = project.markers
        project.split(clipID: clip.id, at: 5)
        project.trim(clipID: clip.id, start: 1, end: 4)
        project.addSpeed(startMs: 0, endMs: 2000, rate: 2)
        project.setClips(project.clips.reversed())
        project.setClips([])
        #expect(project.markers == original)
    }

    @Test func snapUsesInclusiveThresholdAndEarlierFrameForTies() throws {
        var project = VideoProject.create()
        try project.addMarker(atFrame: 104)
        try project.addMarker(atFrame: 100)
        #expect(project.snapToMarker(frame: 102, thresholdFrames: 2) == 100)
        #expect(project.snapToMarker(frame: 102, thresholdFrames: 1) == 102)
        #expect(project.snapToMarker(frame: 104, thresholdFrames: 0) == 104)
        #expect(project.snapToMarker(frame: 103, thresholdFrames: -1) == 103)
        let rate = try VideoMarkerFrameRate(numerator: 60)
        #expect(project.snapToMarker(frame: 201, thresholdFrames: 1, frameRate: rate) == 200)
    }

    @Test func rationalTimecodeUsesExplicitNonDropFrameLabels() throws {
        let rate = try VideoMarkerFrameRate(numerator: 30000, denominator: 1001)
        #expect(rate.timecode(at: 1800) == "00:01:00:00")
        #expect(abs(rate.seconds(at: 1800) - 60.06) < 0.000001)
        let marker = try VideoMarker(frame: 1800, frameRate: rate)
        #expect(marker.timecode == "00:01:00:00 (30000/1001 fps NDF)")
        #expect(!marker.timecode.contains(";"))
        let film = try VideoMarkerFrameRate(numerator: 24000, denominator: 1001)
        #expect(film.timecode(at: 24) == "00:00:01:00")
        #expect(try film.frame(at: film.seconds(at: 86_400)) == 86_400)
        #expect(try VideoMarkerFrameRate(numerator: 60000, denominator: 2002) == rate)
    }

    @Test func rationalRatesAcceptTheVisualSettingsIntegerRange() throws {
        let rate = try VideoMarkerFrameRate(numerator: 2_000_000, denominator: 100_000)
        #expect(rate.numerator == 20 && rate.denominator == 1)
        let maximum = try VideoMarkerFrameRate(numerator: Int(Int32.max), denominator: 100_000_000)
        #expect(maximum.numerator == Int(Int32.max))
        let data = try VideoMarkers.export([VideoMarker(frame: 100, frameRate: maximum)])
        #expect(try VideoMarkers.parse(data).first?.frameRate == maximum)
        #expect(throws: VideoMarkerError.self) {
            try VideoMarkerFrameRate(numerator: Int(Int32.max) + 1, denominator: 100_000_000)
        }
    }

    @Test func invalidImportsAndUpdatesAreAtomic() throws {
        var project = VideoProject.create()
        let marker = try project.addMarker(atFrame: 10)
        #expect(throws: VideoMarkerError.self) { try project.updateMarker(marker.id, frame: -1) }
        #expect(project.markers == [marker])
        for json in [
            "{\"version\":2,\"markers\":[]}",
            "{\"version\":1,\"markers\":[{\"id\":\"bad\",\"frame\":-1,\"frameRate\":{\"numerator\":30,\"denominator\":1},\"label\":\"Bad\",\"kind\":\"manual\"}]}",
            "{\"version\":1,\"markers\":[{\"id\":\"bad\",\"frame\":1,\"frameRate\":{\"numerator\":30,\"denominator\":0},\"label\":\"Bad\",\"kind\":\"manual\"}]}",
        ] {
            #expect(throws: (any Error).self) {
                try project.importMarkers(Data(json.utf8), replace: true)
            }
            #expect(project.markers == [marker])
        }
        #expect(throws: VideoMarkerError.self) { try VideoMarkerFrameRate.fps30.frame(at: .nan) }
        #expect(throws: VideoMarkerError.self) {
            try VideoMarkerFrameRate.fps30.frame(at: .infinity)
        }
        #expect(throws: VideoMarkerError.self) { try VideoMarker(frame: Int64.max) }
    }

    @Test func updatingRatePreservesTimeUnlessFrameIsExplicit() throws {
        var project = VideoProject.create()
        let marker = try project.addMarker(atFrame: 90)
        let rate = try VideoMarkerFrameRate(numerator: 60)
        try project.updateMarker(marker.id, frameRate: rate)
        #expect(project.markers.first?.frame == 180)
        #expect(project.markers.first?.seconds == 3)
        try project.updateMarker(marker.id, frame: 60, frameRate: .fps30)
        #expect(project.markers.first?.seconds == 2)
    }

    @Test func nativeExportPreservesProjectDependenciesAndSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        let media = [
            "source.mov", "audio.caf", "processed.caf", "still.png", "native-still.png",
            "camera.mov",
        ]
        let dependencies =
            ["project.openscreen", "wallpaper.png", "overlay.png", "fallback.png"]
            + media + media.flatMap { [$0 + ".cursor.json", $0 + ".session.json"] }
        let original = Data("synthetic dependency bytes".utf8)
        for name in dependencies { try original.write(to: file(name)) }
        var project = VideoProject(
            root: [
                "assets": [
                    [
                        "id": "video", "originalPath": file("source.mov").path,
                        "edithAudioPath": file("processed.caf").path,
                        "edithSourceImagePath": file("still.png").path,
                        "cameraTrack": ["sourcePath": file("camera.mov").path],
                    ],
                    ["id": "audio", "kind": "audio", "originalPath": file("audio.caf").path],
                    [
                        "id": "still", "kind": "image",
                        "originalPath": file("native-still.png").path,
                    ],
                ],
                "legacyEditor": ["wallpaper": file("wallpaper.png").path],
                "annotations": [
                    [
                        "type": "image", "imageContent": file("overlay.png").path,
                        "content": "unused",
                    ],
                    ["type": "image", "content": file("fallback.png").path],
                    ["type": "image", "imageContent": "data:image/png;base64,c3ludGhldGlj"],
                ],
            ], fileURL: file("project.openscreen"))
        try project.addMarker(atFrame: 30, label: "Synthetic cue")
        for name in dependencies {
            #expect(throws: VideoProjectExportDestination.DestinationError.projectDependency) {
                try project.exportMarkers(to: file(name))
            }
            #expect(try Data(contentsOf: file(name)) == original)
        }
        let sidecar = file("source.mov.cursor.json")
        let symbolic = file("symbolic.json")
        let hard = file("hard.json")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: sidecar)
        try FileManager.default.linkItem(at: sidecar, to: hard)
        for alias in [symbolic, hard] {
            #expect(throws: VideoProjectExportDestination.DestinationError.projectDependency) {
                try project.exportMarkers(to: alias)
            }
            #expect(try Data(contentsOf: alias) == original)
            #expect(try Data(contentsOf: sidecar) == original)
        }
        let destination = file("markers.json")
        try project.exportMarkers(to: destination)
        #expect(try VideoMarkers.parse(Data(contentsOf: destination)) == project.markers)
    }

    @Test func invalidRootEntriesDoNotCrashInspection() {
        let values: [Any] = ["invalid", 17, NSNull(), ["frame": 10]]
        for value in values {
            let project = VideoProject(root: ["edithMarkers": value])
            #expect(project.markers.isEmpty)
        }
    }
}
