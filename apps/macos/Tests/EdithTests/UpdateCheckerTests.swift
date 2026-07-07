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

    @Test func releaseLineParses() {
        let parsed = parseLatestRelease("v1.8.0 https://example.com/Edith-v1.8.0.dmg\n")
        #expect(parsed?.tag == "v1.8.0")
        #expect(parsed?.dmgURL == "https://example.com/Edith-v1.8.0.dmg")
    }

    @Test func releaseLineWithoutAssetParses() {
        let parsed = parseLatestRelease("v1.8.0")
        #expect(parsed?.tag == "v1.8.0")
        #expect(parsed?.dmgURL == nil)
    }

    @Test func malformedReleaseLinesAreRejected() {
        #expect(parseLatestRelease("") == nil)
        #expect(parseLatestRelease("not-a-tag something") == nil)
    }
}
