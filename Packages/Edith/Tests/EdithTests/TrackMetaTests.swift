import EdithKit
import Foundation
import Testing

@MainActor @Suite struct TrackMetaTests {
    @Test func timeLabelHandlesEdgeValues() {
        #expect(TrackMeta.timeLabel(0) == "0:00")
        #expect(TrackMeta.timeLabel(-5) == "0:00")
        #expect(TrackMeta.timeLabel(.nan) == "0:00")
        #expect(TrackMeta.timeLabel(.infinity) == "0:00")
    }

    @Test func timeLabelFormatsMinutesAndHours() {
        #expect(TrackMeta.timeLabel(59) == "0:59")
        #expect(TrackMeta.timeLabel(61) == "1:01")
        #expect(TrackMeta.timeLabel(3599) == "59:59")
        #expect(TrackMeta.timeLabel(3600) == "1:00:00")
        #expect(TrackMeta.timeLabel(3661) == "1:01:01")
    }

    @Test func trackTitleCleansFileName() {
        let track = Track(url: URL(fileURLWithPath: "/tmp/my-song_name.mp3"))
        #expect(track.title == "My Song Name")
    }

    @Test func trackHueIsNormalizedAndStable() {
        let track = Track(url: URL(fileURLWithPath: "/tmp/anything.mp3"))
        #expect(track.hue >= 0)
        #expect(track.hue < 1)
        #expect(track.hue == Track(url: URL(fileURLWithPath: "/tmp/anything.mp3")).hue)
    }

    @Test func playableExtensionsCoverCommonFormats() {
        for ext in ["mp3", "m4a", "wav", "flac", "mp4"] {
            #expect(TrackMeta.playableExtensions.contains(ext))
        }
        #expect(!TrackMeta.playableExtensions.contains("txt"))
        #expect(!TrackMeta.playableExtensions.contains("pdf"))
    }

    @Test func durationIsNilForMissingFile() async {
        let track = Track(url: URL(fileURLWithPath: "/nonexistent/nowhere.mp3"))
        #expect(await TrackMeta.duration(for: track) == nil)
        #expect(await TrackMeta.artwork(for: track) == nil)
    }
}
