import EdithExtensionUI
import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import StudioExtension

@Suite struct StudioFinderRevealTests {
    @Test func scriptEscapesPathsAndCompiles() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/Studio \"quoted\" name.pdf"),
            URL(fileURLWithPath: "/tmp/back\\slash/report.pdf"),
        ]
        let source = StudioFinderReveal.script(for: urls)
        #expect(source.contains(#"POSIX file "/tmp/Studio \"quoted\" name.pdf" as alias"#))
        #expect(source.contains(#"POSIX file "/tmp/back\\slash/report.pdf" as alias"#))
        #expect(source.contains("reveal targets"))
        let script = try #require(NSAppleScript(source: source))
        var error: NSDictionary?
        #expect(script.compileAndReturnError(&error))
        #expect(error == nil)
    }

    @Test func aScriptThatDoesNotReturnGivesUp() async {
        let started = ContinuousClock.now
        let finished = await StudioFinderReveal.runScript("delay 30", timeout: 0.3)
        #expect(!finished)
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func fallbackFoldersAreUnique() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a/one.pdf"), URL(fileURLWithPath: "/tmp/a/two.pdf"),
            URL(fileURLWithPath: "/tmp/b/three.pdf"),
        ]
        let folders = StudioFinderReveal.folders(of: urls).map(\.path)
        #expect(folders == ["/tmp/a", "/tmp/b"])
    }
}
