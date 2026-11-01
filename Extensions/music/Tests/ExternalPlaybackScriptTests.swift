import AppKit
import Testing

@testable import MusicExtension

@Suite struct ExternalPlaybackScriptTests {
    private func reply(artwork: String) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        let items: [NSAppleEventDescriptor] = [
            .init(string: "Dior"), .init(string: "Shubh"), .init(boolean: true),
            .init(double: 137), .init(double: 55), .init(int32: 80),
            .init(boolean: false), .init(boolean: false), .init(boolean: true),
            .init(boolean: true), .init(string: artwork),
        ]
        for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
        return list
    }

    @Test func spotifyScriptAsksForTheAlbumCover() {
        #expect(
            ExternalPlaybackScript.source(app: .spotify).contains("artwork url of current track"))
        #expect(!ExternalPlaybackScript.source(app: .music).contains("artwork url"))
    }

    @Test func parsedPlaybackCarriesASecureArtworkURL() throws {
        let playback = try #require(
            ExternalPlaybackScript.parse(
                reply(artwork: "https://i.scdn.co/image/ab67616d00001e02"), app: .spotify))
        #expect(playback.track.title == "Dior")
        #expect(playback.artworkURL?.host == "i.scdn.co")
        #expect(playback.volume == 0.8)
    }

    @Test func emptyOrInsecureArtworkIsDropped() throws {
        let empty = try #require(ExternalPlaybackScript.parse(reply(artwork: ""), app: .music))
        #expect(empty.artworkURL == nil)
        let insecure = try #require(
            ExternalPlaybackScript.parse(reply(artwork: "http://example.com/a.jpg"), app: .spotify))
        #expect(insecure.artworkURL == nil)
    }
}
