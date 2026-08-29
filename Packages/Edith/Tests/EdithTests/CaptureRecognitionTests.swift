import CoreImage
import Foundation
import Testing

@testable import EdithKit

@Suite struct CaptureRecognitionTests {
    @Test func outputModesKeepTextAndUniqueCodePayloads() {
        let capture = CaptureRecognition(
            text: "invoice 42",
            codes: [
                CaptureCode(symbology: "QR", payload: "https://edith.app"),
                CaptureCode(symbology: "QR", payload: "https://edith.app"),
                CaptureCode(symbology: "QR", payload: "second"),
            ])

        #expect(capture.output(for: .text) == "invoice 42")
        #expect(capture.output(for: .codes) == "https://edith.app\nsecond")
        #expect(capture.output(for: .combined) == "invoice 42\nhttps://edith.app\nsecond")
        #expect(capture.output(for: .smart) == "https://edith.app\nsecond")
    }

    @Test func smartModePrefersASingleCode() {
        let capture = CaptureRecognition(
            text: "printed beside the code",
            codes: [CaptureCode(symbology: "QR", payload: "edith://capture")])
        #expect(capture.output(for: .smart) == "edith://capture")
    }

    @Test func historyHonorsItsLimit() throws {
        let suite = "CaptureRecognitionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CaptureHistoryStore.add(
            CaptureRecognition(text: "first", codes: []), limit: 2, into: defaults)
        CaptureHistoryStore.add(
            CaptureRecognition(text: "second", codes: []), limit: 2, into: defaults)
        CaptureHistoryStore.add(
            CaptureRecognition(text: "third", codes: []), limit: 2, into: defaults)
        #expect(CaptureHistoryStore.load(from: defaults).map(\.text) == ["third", "second"])
    }

    @Test func recognizesQRCodeOffline() throws {
        let filter = try #require(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("edith://capture".utf8), forKey: "inputMessage")
        let output = try #require(filter.outputImage?.transformed(by: .init(scaleX: 12, y: 12)))
        let image = try #require(CIContext().createCGImage(output, from: output.extent))
        let result = try CaptureRecognizer.recognize(image)
        #expect(result.codes.map(\.payload) == ["edith://capture"])
    }

    @Test func recognizesLinearBarcodeOffline() throws {
        let filter = try #require(CIFilter(name: "CICode128BarcodeGenerator"))
        filter.setValue(Data("EDITH-128".utf8), forKey: "inputMessage")
        let output = try #require(filter.outputImage?.transformed(by: .init(scaleX: 4, y: 4)))
        let image = try #require(CIContext().createCGImage(output, from: output.extent))
        let result = try CaptureRecognizer.recognize(image)
        #expect(result.codes.map(\.payload).contains("EDITH-128"))
    }

    @Test func onlyStrictWebLinksCanOpen() {
        #expect(CaptureRecognizedLink.openable("https://edith.app/capture") != nil)
        #expect(CaptureRecognizedLink.openable("http://localhost:8080") != nil)
        #expect(CaptureRecognizedLink.openable("javascript:alert(1)") == nil)
        #expect(CaptureRecognizedLink.openable("https://edith.app/a b") == nil)
        #expect(CaptureRecognizedLink.openable("https:///missing-host") == nil)
        #expect(CaptureRecognizedLink.openable("https://edith.app@example.com") == nil)
    }

    @Test func archiveNeverOverwritesACaptureFromTheSameSecond() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try CaptureScreenshotArchive.save(Data([1]), to: directory, now: now)
        let second = try CaptureScreenshotArchive.save(Data([2]), to: directory, now: now)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(try Data(contentsOf: second) == Data([2]))
    }
}
