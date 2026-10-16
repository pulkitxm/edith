import EdithExtensionSupport
import Foundation
import Testing
@testable import ColorPickerExtension

struct ColorPickerExtensionSurfaceTests {
    private func entry(_ id: String, _ preview: String, pinned: Bool = false, age: TimeInterval = 0)
        -> ColorPickerClipboardEntry
    {
        .init(
            id: id, ext: "txt", sourceApp: "Figma",
            lastCopiedAt: Date(timeIntervalSince1970: 1_000 - age), preview: preview,
            pinned: pinned)
    }

    @Test func clipboardColorsBecomeRowsWithCopyAndPin() async throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let snapshot = try await ColorPickerSurface.snapshot(
            tile: SurfaceTile(.ability("colorPicker")), clipboardActive: true,
            pinToTop: true,
            entries: {
                [
                    entry(UUID().uuidString, "hello world"),
                    entry(first, "#FF0000", age: 10),
                    entry(second, "rgb(1, 2, 3)", pinned: true, age: 50),
                ]
            })
        #expect(snapshot.rows.map(\.id) == [second, first])
        #expect(snapshot.metrics.map(\.value) == ["2", "1"])
        #expect(snapshot.rows.first?.actions.map(\.id) == ["copy/" + second, "pin/" + second])
        #expect(snapshot.rows.first?.actions.last?.title == "Unpin")
        #expect(snapshot.actions.first?.id == "pick")
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "colorPicker")
    }

    @Test func inactiveClipboardOnlyOffersThePicker() async throws {
        let snapshot = try await ColorPickerSurface.snapshot(
            tile: SurfaceTile(.ability("colorPicker")), clipboardActive: false,
            pinToTop: true, entries: { throw ExtensionPeerError.unavailable })
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.actions.first?.id == "pick")
        #expect(snapshot.message == ColorPickerSurface.pickMessage)
    }

    @Test func recognisesColourStrings() {
        #expect(ColorPickerSurface.isColor("#abc"))
        #expect(ColorPickerSurface.isColor("hsl(10, 50%, 50%)"))
        #expect(!ColorPickerSurface.isColor("#abcd1"))
        #expect(!ColorPickerSurface.isColor("rgb(1, 2)"))
        #expect(!ColorPickerSurface.isColor("blue"))
    }
}
