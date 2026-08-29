import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CaptureEditorModel {
    let sourceImage: NSImage
    let sourceCGImage: CGImage
    var document = CaptureEditDocument()
    var tool: CaptureEditTool = .arrow
    var color = Color.red
    var strokeWidth = 5.0
    var text = "Note"
    var draft: CaptureAnnotation?
    private var dragPoints: [CGPoint] = []

    init?(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        sourceImage = image
        sourceCGImage = cgImage
    }

    var sourceSize: CGSize {
        CGSize(width: sourceCGImage.width, height: sourceCGImage.height)
    }

    func begin(at point: CGPoint) {
        dragPoints = [clamped(point)]
        updateDraft()
    }

    func move(to point: CGPoint) {
        guard !dragPoints.isEmpty else { return }
        let point = clamped(point)
        if tool == .pen {
            if let last = dragPoints.last, hypot(last.x - point.x, last.y - point.y) >= 2 {
                dragPoints.append(point)
            }
        } else if dragPoints.count == 1 {
            dragPoints.append(point)
        } else {
            dragPoints[dragPoints.count - 1] = point
        }
        updateDraft()
    }

    func end(at point: CGPoint) {
        move(to: point)
        guard let draft else { return }
        if tool == .crop {
            if draft.rect.width >= 8, draft.rect.height >= 8 {
                document.cropRect = draft.rect
            }
        } else if tool == .text {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                document.annotations.append(
                    CaptureAnnotation(
                        tool: .text,
                        points: [draft.points[0], CGPoint(x: draft.points[0].x + 320, y: draft.points[0].y + 80)],
                        text: value, colorHex: colorHex, strokeWidth: strokeWidth))
            }
        } else if tool == .pen || draft.rect.width >= 3 || draft.rect.height >= 3 {
            document.annotations.append(draft)
        }
        self.draft = nil
        dragPoints = []
    }

    func undo() {
        if !document.annotations.isEmpty {
            document.annotations.removeLast()
        } else {
            document.cropRect = nil
        }
    }

    func resetCrop() {
        document.cropRect = nil
    }

    func exportData() throws -> Data {
        try CaptureRenderer.pngData(baseImage: sourceCGImage, document: document)
    }

    private func updateDraft() {
        let points: [CGPoint]
        if tool == .text {
            points = [dragPoints[0], CGPoint(x: dragPoints[0].x + 320, y: dragPoints[0].y + 80)]
        } else {
            points = dragPoints
        }
        draft = CaptureAnnotation(
            tool: tool, points: points, text: text, colorHex: colorHex,
            strokeWidth: strokeWidth)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), sourceSize.width),
            y: min(max(point.y, 0), sourceSize.height))
    }

    private var colorHex: String {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .systemRed
        return String(
            format: "#%02X%02X%02X", Int(converted.redComponent * 255),
            Int(converted.greenComponent * 255), Int(converted.blueComponent * 255))
    }
}
