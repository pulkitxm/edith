import AppKit
import Testing
@testable import AudioMixerExtension

@Suite struct AudioMixerIconTests {
    @Test func largeIconsShrinkToSmallPNG() throws {
        let icon = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let data = try #require(AudioMixerIcon.png(icon))
        #expect(data.count < 16 * 1024)
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == AudioMixerIcon.pixels)
        #expect(AudioMixerIcon.png(nil) == nil)
    }
}
