import CoreGraphics
import Foundation
import PDFKit

public enum PDFComparison {
    public enum Side: String, Sendable {
        case original
        case revised
    }

    public struct Change: Identifiable, Equatable, Sendable {
        public let id: Int
        public let side: Side
        public let text: String
        public let page: Int
        public let rect: CGRect
    }

    public struct Report: Sendable {
        public let changes: [Change]
        public let originalPages: Int
        public let revisedPages: Int

        public var removed: [Change] { changes.filter { $0.side == .original } }
        public var added: [Change] { changes.filter { $0.side == .revised } }
        public var isIdentical: Bool { changes.isEmpty && originalPages == revisedPages }

        public var summary: String {
            if isIdentical { return "No text differences found." }
            let removedCount = removed.count
            let addedCount = added.count
            return
                "\(removedCount) line\(removedCount == 1 ? "" : "s") removed, \(addedCount) line\(addedCount == 1 ? "" : "s") added."
        }
    }

    struct Entry {
        let key: String
        let text: String
        let page: Int
        let rect: CGRect
    }

    static func entries(_ document: PDFDocument) -> [Entry] {
        var result: [Entry] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for line in PDFTextAnalysis.lines(of: page) {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let key = text.lowercased().split(whereSeparator: \.isWhitespace).joined(
                    separator: " ")
                result.append(Entry(key: key, text: text, page: index, rect: line.rect))
            }
        }
        return result
    }

    public static func compare(_ original: PDFDocument, _ revised: PDFDocument) -> Report {
        let left = entries(original)
        let right = entries(revised)
        let difference = right.map(\.key).difference(from: left.map(\.key))
        var changes: [Change] = []
        var identifier = 0
        for change in difference {
            identifier += 1
            switch change {
            case let .remove(offset, _, _):
                let entry = left[offset]
                changes.append(
                    Change(
                        id: identifier, side: .original, text: entry.text, page: entry.page,
                        rect: entry.rect))
            case let .insert(offset, _, _):
                let entry = right[offset]
                changes.append(
                    Change(
                        id: identifier, side: .revised, text: entry.text, page: entry.page,
                        rect: entry.rect))
            }
        }
        changes.sort {
            ($0.page, -$0.rect.midY, $0.side.rawValue) < ($1.page, -$1.rect.midY, $1.side.rawValue)
        }
        return Report(
            changes: changes, originalPages: original.pageCount, revisedPages: revised.pageCount)
    }

    public static func visualDifference(
        _ original: PDFPage, _ revised: PDFPage, dpi: Double = 72
    ) throws -> (image: CGImage, changedFraction: Double) {
        let left = try StudioPDF.render(original, dpi: dpi)
        let right = try StudioPDF.render(revised, dpi: dpi)
        let width = max(left.width, right.width)
        let height = max(left.height, right.height)
        guard let a = bitmap(left, width: width, height: height),
            let b = bitmap(right, width: width, height: height),
            let output = StudioImageOps.context(width: width, height: height, opaque: true)
        else { throw StudioError.failed("Not enough memory to compare these pages.") }
        output.draw(
            right,
            in: CGRect(x: 0, y: height - right.height, width: right.width, height: right.height))
        guard let base = output.data else { throw StudioError.failed("Comparison failed.") }
        let bytes = base.bindMemory(to: UInt8.self, capacity: output.bytesPerRow * height)
        var changed = 0
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * width * 4 + column * 4
                let red = abs(Int(a[offset]) - Int(b[offset]))
                let green = abs(Int(a[offset + 1]) - Int(b[offset + 1]))
                let blue = abs(Int(a[offset + 2]) - Int(b[offset + 2]))
                let delta = red + green + blue
                guard delta > 48 else { continue }
                changed += 1
                let target = row * output.bytesPerRow + column * 4
                bytes[target] = 235
                bytes[target + 1] = UInt8(Double(bytes[target + 1]) * 0.35)
                bytes[target + 2] = UInt8(Double(bytes[target + 2]) * 0.35)
            }
        }
        guard let image = output.makeImage() else { throw StudioError.failed("Comparison failed.") }
        return (image, Double(changed) / Double(max(width * height, 1)))
    }

    static func bitmap(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(
                image,
                in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height)
            )
            return true
        }
        return drawn ? buffer : nil
    }

    public static func markdownReport(_ report: Report, original: String, revised: String) -> String
    {
        var lines = [
            "# Comparison", "", "- Original: \(original) (\(report.originalPages) pages)",
            "- Revised: \(revised) (\(report.revisedPages) pages)", "- \(report.summary)", "",
        ]
        for change in report.changes {
            let marker = change.side == .original ? "-" : "+"
            let page = change.page + 1
            lines.append("\(marker) p\(page): \(change.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static let tool = StudioTool(
        id: "pdf.compare", title: "Compare PDF",
        summary: "See two versions side by side with every added and removed line highlighted.",
        symbol: "rectangle.split.2x1", group: .organize, inputs: [.pdf],
        arity: .combine(minimum: 2, maximum: 2), produces: .report,
        options: [PDFOrganizeTools.passwordOption], style: .compare,
        keywords: ["diff", "difference", "changes", "versions", "redline"], actionTitle: "Compare"
    ) { run in
        let original = try StudioPDF.open(run.inputs[0], password: run.settings.text("password"))
        let revised = try StudioPDF.open(run.inputs[1], password: run.settings.text("password"))
        let report = compare(original, revised)
        let output = run.output(for: run.inputs[1], suffix: "comparison", ext: "md")
        try markdownReport(
            report, original: run.inputs[0].lastPathComponent,
            revised: run.inputs[1].lastPathComponent
        ).write(to: output, atomically: true, encoding: .utf8)
        run.note(report.summary)
        return [output]
    }
}
