import Foundation
import Testing

@testable import EdithKit

private let sampleCatalog = """
    {"schema":1,"source":"test","groups":[
    {"id":"smileys-emotion","name":"Smileys","symbol":"face.smiling"},
    {"id":"people-body","name":"People","symbol":"hand.wave"}],
    "emoji":[
    {"e":"😀","n":"grinning face","g":0,"v":1,"t":["happy","smile"]},
    {"e":"👍","n":"thumbs up","g":1,"v":0.6,"t":["+1","thumbsup"],
    "s":["👍🏻","👍🏼","👍🏽","👍🏾","👍🏿"]},
    {"e":"🫩","n":"face with bags under eyes","g":0,"v":16}]}
    """

private func decodedSample() throws -> EmojiCatalog {
    try EmojiCatalog.decode(Data(sampleCatalog.utf8))
}

@Suite struct EmojiCatalogTests {
    @Test func decodeReadsGroupsTermsAndSkinTones() throws {
        let catalog = try decodedSample()
        #expect(catalog.groups.map(\.name) == ["Smileys", "People"])
        #expect(catalog.groups[0].symbolName == "face.smiling")
        #expect(catalog.emoji.count == 3)
        let thumbsUp = try #require(catalog.emoji.first { $0.name == "thumbs up" })
        #expect(thumbsUp.groupIndex == 1)
        #expect(thumbsUp.supportsSkinTones)
        #expect(thumbsUp.toneVariants.count == 5)
        #expect(thumbsUp.terms == ["+1", "thumbsup"])
    }

    @Test func skinToneSelectionFallsBackToTheBaseCharacter() throws {
        let catalog = try decodedSample()
        let thumbsUp = try #require(catalog.emoji.first { $0.name == "thumbs up" })
        #expect(thumbsUp.character(tone: .standard) == "👍")
        #expect(thumbsUp.character(tone: .light) == "👍🏻")
        #expect(thumbsUp.character(tone: .dark) == "👍🏿")
        let grinning = try #require(catalog.emoji.first { $0.name == "grinning face" })
        #expect(grinning.character(tone: .dark) == "😀")
    }

    @Test func filteringDropsUnsupportedEmojiAndRemapsGroups() throws {
        let catalog = try decodedSample()
        let filtered = catalog.filtered { $0 != "🫩" && $0 != "😀" }
        #expect(filtered.emoji.map(\.character) == ["👍"])
        #expect(filtered.groups.map(\.name) == ["People"])
        #expect(filtered.emoji[0].groupIndex == 0)
        #expect(filtered.group(at: 0)?.id == "people-body")
    }

    @Test func filteringDropsSkinTonesWhenAnyVariantIsUnsupported() throws {
        let catalog = try decodedSample()
        let filtered = catalog.filtered { $0 != "👍🏿" }
        let thumbsUp = try #require(filtered.emoji.first { $0.name == "thumbs up" })
        #expect(thumbsUp.toneVariants.isEmpty)
        #expect(!thumbsUp.supportsSkinTones)
    }

    @Test func lookupResolvesTonedCharactersBackToTheBaseEmoji() throws {
        let catalog = try decodedSample()
        #expect(catalog.emoji(matching: "👍🏽")?.name == "thumbs up")
        #expect(catalog.emoji(matching: "😀")?.name == "grinning face")
        #expect(catalog.emoji(matching: "🚀") == nil)
    }

    @Test func bundledCatalogLoadsEveryGroupWithRenderableEmoji() {
        let catalog = EmojiCatalog.shared
        #expect(catalog.emoji.count > 1_500)
        #expect(catalog.groups.count == 9)
        #expect(catalog.emoji.contains { $0.supportsSkinTones })
        #expect(catalog.emoji.allSatisfy { !$0.character.isEmpty })
        for index in catalog.groups.indices {
            #expect(!catalog.emoji(inGroup: index).isEmpty)
        }
    }

    @Test func bundledCatalogOnlyContainsCharactersThisMacRenders() {
        for entry in EmojiCatalog.shared.emoji {
            #expect(EmojiGlyphSupport.isRenderable(entry.character))
            for tone in entry.toneVariants {
                #expect(EmojiGlyphSupport.isRenderable(tone))
            }
        }
    }
}

@Suite struct EmojiGlyphSupportTests {
    @Test func ligatureRuleRequiresASingleGlyphForUnjoinedSequences() {
        #expect(EmojiGlyphSupport.isLigated(glyphs: 1, segments: 1))
        #expect(!EmojiGlyphSupport.isLigated(glyphs: 2, segments: 1))
        #expect(EmojiGlyphSupport.isLigated(glyphs: 1, segments: 4))
        #expect(EmojiGlyphSupport.isLigated(glyphs: 2, segments: 4))
        #expect(!EmojiGlyphSupport.isLigated(glyphs: 2, segments: 2))
    }

    @Test func joinedSegmentsCountsZeroWidthJoinerParts() {
        #expect(EmojiGlyphSupport.joinedSegments("😀") == 1)
        #expect(EmojiGlyphSupport.joinedSegments("🇮🇳") == 1)
        #expect(EmojiGlyphSupport.joinedSegments("👨‍👩‍👧‍👦") == 4)
        #expect(EmojiGlyphSupport.joinedSegments("🏳️‍🌈") == 2)
    }

    @Test func renderabilityAcceptsRealEmojiAndRejectsBrokenSequences() {
        #expect(EmojiGlyphSupport.isRenderable("😀"))
        #expect(EmojiGlyphSupport.isRenderable("👨‍👩‍👧‍👦"))
        #expect(EmojiGlyphSupport.isRenderable("👩‍❤️‍💋‍👨"))
        #expect(EmojiGlyphSupport.isRenderable("🇮🇳"))
        #expect(EmojiGlyphSupport.isRenderable("5️⃣"))
        #expect(!EmojiGlyphSupport.isRenderable("A"))
        #expect(!EmojiGlyphSupport.isRenderable(""))
        #expect(!EmojiGlyphSupport.isRenderable("\u{1F44D}\u{200D}\u{1F680}"))
        #expect(!EmojiGlyphSupport.isRenderable("\u{1F1FD}\u{1F1FF}"))
        #expect(!EmojiGlyphSupport.isRenderable("\u{1F600}\u{1F3FB}"))
    }
}
