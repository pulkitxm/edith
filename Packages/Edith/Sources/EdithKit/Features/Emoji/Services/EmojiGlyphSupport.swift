import CoreText
import Foundation

public enum EmojiGlyphSupport {
    public static let fontName = "Apple Color Emoji"

    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"

    private static let font: CTFont? = {
        let candidate = CTFontCreateWithName(fontName as CFString, 16, nil)
        return isEmojiFont(candidate) ? candidate : nil
    }()

    public static func isRenderable(_ character: String) -> Bool {
        guard let font else { return true }
        guard let glyphs = emojiGlyphCount(character, font: font), glyphs > 0 else { return false }
        return isLigated(glyphs: glyphs, segments: joinedSegments(character))
    }

    public static func joinedSegments(_ character: String) -> Int {
        character.unicodeScalars.split(separator: zeroWidthJoiner).count
    }

    public static func isLigated(glyphs: Int, segments: Int) -> Bool {
        segments <= 1 ? glyphs == 1 : glyphs < segments
    }

    private static func emojiGlyphCount(_ character: String, font: CTFont) -> Int? {
        let attributed = NSAttributedString(
            string: character,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        var total = 0
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            total += count
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            guard !glyphs.contains(0), let runFont = runFont(of: run), isEmojiFont(runFont) else {
                return nil
            }
        }
        return total
    }

    private static func runFont(of run: CTRun) -> CTFont? {
        guard let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName],
            CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID()
        else { return nil }
        return unsafeBitCast(value as AnyObject, to: CTFont.self)
    }

    private static func isEmojiFont(_ font: CTFont) -> Bool {
        let name = CTFontCopyPostScriptName(font) as String
        return name.replacingOccurrences(of: "-", with: "") == "AppleColorEmoji"
    }
}
