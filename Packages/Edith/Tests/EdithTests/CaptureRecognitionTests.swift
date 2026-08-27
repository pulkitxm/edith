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

    @Test func onlyStrictWebLinksCanOpen() {
        #expect(CaptureRecognizedLink.openable("https://edith.app/capture") != nil)
        #expect(CaptureRecognizedLink.openable("http://localhost:8080") != nil)
        #expect(CaptureRecognizedLink.openable("javascript:alert(1)") == nil)
        #expect(CaptureRecognizedLink.openable("https://edith.app/a b") == nil)
        #expect(CaptureRecognizedLink.openable("https:///missing-host") == nil)
    }
}
