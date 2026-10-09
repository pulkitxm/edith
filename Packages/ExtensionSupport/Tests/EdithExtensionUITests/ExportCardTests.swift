import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized)
struct ExportCardTests {
    @Test func syntheticArtworkRendersAtDeclaredExportDimensions() throws {
        let data = try ExportCardRenderer.pngData(
            ZStack {
                Color.blue; Text("Sample usage").foregroundStyle(.white)
            }, scale: 1)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 1_200)
        #expect(bitmap.pixelsHigh == 800)
        #expect(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
    }

    @Test func deliveryPreservesPNGBytesInOwnedPasteboardAndAtomicFile() throws {
        let data = try ExportCardRenderer.pngData(Text("Sample report"), scale: 1)
        let pasteboard = NSPasteboard(name: .init("export-fixture-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try ExportDelivery.copyPNG(data, to: pasteboard)
        #expect(pasteboard.data(forType: .png) == data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try ExportDelivery.write(data, to: url)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func cancelledSaveDoesNotPresentAPanel() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ExportDelivery.chooseSaveURL(suggestedName: "sample.png", in: nil)
        }
        #expect(await task.value == nil)
    }
}
