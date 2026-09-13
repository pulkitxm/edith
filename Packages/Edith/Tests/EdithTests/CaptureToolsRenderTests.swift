import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct CaptureToolsRenderTests {
    @Test func recognizedSyntheticScreenRendersInPreview() throws {
        let image = NSImage(size: NSSize(width: 640, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        ("Project Atlas" as NSString).draw(at: NSPoint(x: 36, y: 156), withAttributes: style)
        ("Design review at 10:30" as NSString).draw(
            at: NSPoint(x: 36, y: 100), withAttributes: style)
        ("Bring the launch checklist" as NSString).draw(
            at: NSPoint(x: 36, y: 44), withAttributes: style)
        image.unlockFocus()
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let recognition = try CaptureRecognizer.recognize(pixels, detectCodes: false)
        #expect(recognition.text.contains("Project Atlas"))
        let view = CapturePreviewView(
            image: image, recognition: recognition, operation: .read, copyMode: .smart,
            copiedResult: true, copyImage: {}, saveImage: {}, copyResult: {}, openResult: {},
            discard: {}, hovering: { _ in }
        )
        .frame(width: 440, height: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 390)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 440)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("capture-tools.png"))
        }
    }
}
