import Foundation
import Testing

@testable import EdithMenuBar

@Suite struct UpdateCheckerTests {
    @Test func newerVersionsAreDetected() {
        #expect(isNewerVersion("v1.8.0", than: "1.7.0"))
        #expect(isNewerVersion("v2.0.0", than: "1.9.9"))
        #expect(isNewerVersion("v1.7.1", than: "1.7.0"))
        #expect(isNewerVersion("v1.7.0.1", than: "1.7.0"))
    }

    @Test func equalOrOlderVersionsAreNot() {
        #expect(!isNewerVersion("v1.7.0", than: "1.7.0"))
        #expect(!isNewerVersion("v1.6.9", than: "1.7.0"))
        #expect(!isNewerVersion("v1.7.0", than: "1.7.0.1"))
        #expect(!isNewerVersion("garbage", than: "1.7.0"))
    }

    @Test func releaseJSONDecodes() throws {
        let json = """
            {
              "tag_name": "v1.9.0",
              "assets": [
                {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                {"name": "Edith-v1.9.0.dmg",
                 "browser_download_url": "https://example.com/Edith-v1.9.0.dmg"}
              ]
            }
            """
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v1.9.0")
        #expect(release.dmgDownloadURL?.absoluteString == "https://example.com/Edith-v1.9.0.dmg")
    }

    @Test func releaseWithoutDMGHasNoDownloadURL() throws {
        let json = """
            {"tag_name": "v1.9.0", "assets": []}
            """
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        #expect(release.tagName == "v1.9.0")
        #expect(release.dmgDownloadURL == nil)
    }
}
