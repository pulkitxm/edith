import AppKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardPayloadTests {
    private let options = ClipboardCaptureOptions(
        saveFiles: true, saveImages: true, saveText: true)

    @Test func uuidNamedFilesShowTheirKindInsteadOfTheUUID() {
        let uuid = "86789B21-5238-4B94-8DCC-BAC684D59D6E"
        #expect(ClipboardPayloadExtractor.isOpaqueName("\(uuid).png"))
        #expect(ClipboardPayloadExtractor.isOpaqueName(uuid))
        #expect(!ClipboardPayloadExtractor.isOpaqueName("budget.png"))
        #expect(!ClipboardPayloadExtractor.isOpaqueName("Screenshot 2026-07-21.png"))

        let url = URL(fileURLWithPath: "/tmp/\(uuid).png")
        let kind = ClipboardPayloadExtractor.kindDescription(for: url)
        #expect(kind?.isEmpty == false)
        #expect(kind?.localizedCaseInsensitiveContains("png") == true)
        let extensionless = URL(fileURLWithPath: "/tmp/x")
        #expect(ClipboardPayloadExtractor.kindDescription(for: extensionless) == nil)
    }

    @Test @MainActor func symbolHeavyTextHasPreview() throws {
        let input = ".^!7JY555555YJ?7!^:.:~?5GGBBB#BBBBBGGGGGGGGPY7"
        let pasteboard = makePasteboard()
        pasteboard.setString(input, forType: .string)

        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.preview == input)
        #expect(payload.ext == "txt")
        #expect(String(data: payload.data, encoding: .utf8) == input)
    }

    @Test @MainActor func richTextUsesPlainTextFallback() throws {
        let input = ".^!7JY555555YJ?7!^:.:~?5GGBBB#BBBBBGGGGGGGGPY7"
        let pasteboard = makePasteboard()
        let empty = NSAttributedString(string: "")
        let rtf = try #require(
            empty.rtf(
                from: NSRange(location: 0, length: empty.length), documentAttributes: [:]))
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(input, forType: .string)

        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.ext == "rtf")
        #expect(payload.preview == input)
    }

    @Test @MainActor func largeTextKeepsFullPayloadAndBoundsPreview() throws {
        let input = String(repeating: "abcdefghij", count: 10_000)
        let pasteboard = makePasteboard()
        pasteboard.setString(input, forType: .string)

        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.preview.count == 500)
        #expect(payload.preview == String(input.prefix(500)))
        #expect(payload.data == Data(input.utf8))
    }

    @Test @MainActor func whitespaceAndEmptyTextHaveFallbackPreviews() throws {
        let whitespacePasteboard = makePasteboard()
        whitespacePasteboard.setString(" \n\t", forType: .string)
        let whitespace = try #require(
            ClipboardPayloadExtractor.extract(from: whitespacePasteboard, options: options))

        let emptyPasteboard = makePasteboard()
        emptyPasteboard.setString("", forType: .string)
        let empty = try #require(
            ClipboardPayloadExtractor.extract(from: emptyPasteboard, options: options))

        #expect(whitespace.preview == "Whitespace text")
        #expect(empty.preview == "Empty text")
    }

    @Test @MainActor func typedJsonIsCapturedWithoutStandardString() throws {
        let json = #"{"project":"edith","values":[1,2,3]}"#
        let pasteboard = makePasteboard()
        pasteboard.setData(Data(json.utf8), forType: .init("public.json"))

        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.ext == "json")
        #expect(payload.preview == json)
        #expect(payload.types == ["public.json"])
    }

    @Test @MainActor func utf16TypedTextIsDecoded() throws {
        let text = "column\tvalue\nalpha\t42"
        let pasteboard = makePasteboard()
        let data = try #require(text.data(using: .utf16LittleEndian))
        pasteboard.setData(data, forType: .init("public.utf16-external-plain-text"))

        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.preview == text)
        #expect(payload.ext == "tsv")
    }

    @Test @MainActor func commonImageAndDocumentFormatsAreTyped() throws {
        let imagePasteboard = makePasteboard()
        imagePasteboard.setData(Data([0xFF, 0xD8, 0xFF]), forType: .init("public.jpeg"))
        let image = try #require(
            ClipboardPayloadExtractor.extract(from: imagePasteboard, options: options))

        let pdfPasteboard = makePasteboard()
        pdfPasteboard.setData(Data("%PDF-1.7".utf8), forType: .pdf)
        let pdf = try #require(
            ClipboardPayloadExtractor.extract(from: pdfPasteboard, options: options))

        #expect(image.ext == "jpg")
        #expect(image.preview == "JPEG image")
        #expect(pdf.ext == "pdf")
        #expect(pdf.preview == "PDF document")
    }

    @Test @MainActor func multipleFilesAndFoldersHaveUsefulPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("fixtures")
        let file = root.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = makePasteboard()
        pasteboard.writeObjects([folder as NSURL, file as NSURL])
        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.ext == "files")
        #expect(payload.preview.contains("2 items"))
        #expect(payload.preview.contains("fixtures · Folder"))
        #expect(payload.preview.contains("events.jsonl"))
    }

    @Test @MainActor func textFilePreviewReadsOnlyInitialContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = root.appendingPathComponent("events.jsonl")
        let beginning = #"{"event":"clipboard","sequence":1}"#
        let content = beginning + String(repeating: "x", count: 100_000)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = makePasteboard()
        pasteboard.writeObjects([file as NSURL])
        let payload = try #require(
            ClipboardPayloadExtractor.extract(from: pasteboard, options: options))

        #expect(payload.preview.hasPrefix("events.jsonl · \(beginning)"))
        #expect(payload.preview.count <= 500)
        #expect(payload.data == Data(file.absoluteString.utf8))
    }

    @Test func historicalBlankEntriesHaveDisplayFallbacks() {
        let entry = ClipboardEntry(
            sha256: "abc", types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: nil, sourceBundleID: nil, size: 0, preview: "\n\t")

        #expect(entry.displayPreview == "Text")
    }

    @Test @MainActor func disabledTextCaptureDoesNotFallThroughAsBinary() {
        let pasteboard = makePasteboard()
        pasteboard.setData(Data(#"{"value":42}"#.utf8), forType: .init("com.example.snippet"))
        let options = ClipboardCaptureOptions(saveFiles: true, saveImages: true, saveText: false)

        let payload = ClipboardPayloadExtractor.extract(from: pasteboard, options: options)

        #expect(payload == nil)
    }

    @MainActor private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("ClipboardPayloadTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}
