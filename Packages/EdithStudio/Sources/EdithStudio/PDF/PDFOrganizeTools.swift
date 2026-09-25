import AppKit
import CoreGraphics
import Foundation
import PDFKit

public enum StudioPaperSize: String, CaseIterable, Sendable {
    case a3, a4, a5, letter, legal, tabloid

    public var points: CGSize {
        switch self {
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .tabloid: CGSize(width: 792, height: 1224)
        }
    }

    public var title: String {
        switch self {
        case .a3: "A3"
        case .a4: "A4"
        case .a5: "A5"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .tabloid: "Tabloid"
        }
    }

    static var choices: [StudioChoice] { allCases.map { StudioChoice($0.rawValue, $0.title) } }
}

enum PDFOrganizeTools {
    static let passwordOption = StudioOption.password(
        "password", "Password", help: "Only needed when the PDF is locked.")

    static var all: [StudioTool] {
        [merge, split, removePages, reorder, rotate, organize, nUp, resize, crop, cropVisual]
    }

    static let merge = StudioTool(
        id: "pdf.merge", title: "Merge PDF",
        summary: "Combine PDFs and images into one PDF in the order you want.",
        symbol: "square.stack.3d.down.right", group: .organize, inputs: [.pdf, .image],
        arity: .combine(minimum: 2, maximum: nil), produces: .kind(.pdf),
        options: [
            .toggle(
                "bookmarks", "Add a bookmark for each file", default: true,
                help: "Adds an outline entry at the start of every merged file."),
            passwordOption,
        ],
        keywords: ["combine", "join", "append"], actionTitle: "Merge", family: .pdf
    ) { run in
        let merged = PDFDocument()
        let outline = PDFOutline()
        var sources: [PDFDocument] = []
        for (index, url) in run.inputs.enumerated() {
            try run.checkCancellation()
            run.status("Adding \(url.lastPathComponent)")
            let start = merged.pageCount
            if url.studioKind == .image {
                let image = try StudioImageIO.load(url)
                if let page = ImagesToPDF.page(for: image, layout: .init()) {
                    merged.insert(page, at: merged.pageCount)
                }
            } else {
                let document = try StudioPDF.open(url, password: run.settings.text("password"))
                sources.append(document)
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else {
                        continue
                    }
                    merged.insert(page, at: merged.pageCount)
                }
            }
            if run.settings.bool("bookmarks"), merged.pageCount > start,
                let first = merged.page(at: start)
            {
                let item = PDFOutline()
                item.label = url.studioStem
                item.destination = PDFDestination(
                    page: first, at: CGPoint(x: 0, y: first.bounds(for: .mediaBox).maxY))
                outline.insertChild(item, at: outline.numberOfChildren)
            }
            run.progress(Double(index + 1) / Double(run.inputs.count) * 0.9)
        }
        guard merged.pageCount > 0 else {
            throw StudioError.nothingToDo("None of the files had pages to merge.")
        }
        if outline.numberOfChildren > 0 { merged.outlineRoot = outline }
        let output = run.output(for: run.inputs[0], suffix: "merged", ext: "pdf")
        try StudioPDF.write(merged, to: output)
        _ = sources.count
        return [output]
    }

    static let split = StudioTool(
        id: "pdf.split", title: "Split PDF",
        summary: "Separate pages into several PDFs, by ranges, a fixed size or every page.",
        symbol: "rectangle.split.3x1", group: .organize, inputs: [.pdf],
        produces: .kind(.pdf),
        options: [
            .choice(
                "mode", "Split",
                [
                    StudioChoice("ranges", "By ranges"), StudioChoice("every", "Every N pages"),
                    StudioChoice("pages", "Every page"),
                    StudioChoice("extract", "Extract into one PDF"),
                ], default: "ranges"),
            .text(
                "ranges", "Ranges", placeholder: "1-3, 4-7, 8-",
                default: "1-1, 2-",
                help: "Each comma separated range becomes its own PDF.",
                when: .init("mode", ["ranges"])),
            .text(
                "extract", "Pages to extract", placeholder: "1, 3-5, last", default: "1",
                help: "Selected pages are copied into one new PDF.",
                when: .init("mode", ["extract"])),
            .integer("size", "Pages per file", 1...500, default: 2, when: .init("mode", ["every"])),
            passwordOption,
        ],
        keywords: ["separate", "extract", "divide", "pages"], groupsOutputs: true,
        actionTitle: "Split"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let count = document.pageCount
        var groups: [[Int]]
        switch run.settings.text("mode") {
        case "every":
            let size = max(1, run.settings.int("size"))
            groups = stride(from: 0, to: count, by: size).map {
                Array($0..<min($0 + size, count))
            }
        case "pages":
            groups = (0..<count).map { [$0] }
        case "extract":
            groups = [try StudioPageSelection.pages(run.settings.text("extract"), pageCount: count)]
        default:
            groups = try StudioPageSelection.groups(run.settings.text("ranges"), pageCount: count)
        }
        groups = groups.filter { !$0.isEmpty }
        let width = String(count).count
        var outputs: [URL] = []
        for (index, group) in groups.enumerated() {
            try run.checkCancellation()
            let part = PDFDocument()
            for pageIndex in group {
                if let page = document.page(at: pageIndex)?.copy() as? PDFPage {
                    part.insert(page, at: part.pageCount)
                }
            }
            let label: String
            if run.settings.text("mode") == "extract" {
                label = "extracted"
            } else if group.count == 1 {
                label = "page-" + String(format: "%0\(width)d", group[0] + 1)
            } else {
                label = StudioPageSelection.label(for: group)
            }
            let output = run.output(for: run.input, suffix: label, ext: "pdf")
            try StudioPDF.write(part, to: output)
            outputs.append(output)
            run.progress(Double(index + 1) / Double(groups.count))
        }
        return outputs
    }

    static let removePages = StudioTool(
        id: "pdf.remove-pages", title: "Remove pages",
        summary: "Delete the pages you do not need from a PDF.",
        symbol: "minus.rectangle", group: .organize, inputs: [.pdf], produces: .kind(.pdf),
        options: [
            .text(
                "pages", "Pages to remove", placeholder: "2, 5-7, last", default: "",
                help: "Examples: 2, 5-7, odd, even, last.", required: true),
            .toggle("blank", "Also remove blank pages", default: false),
            passwordOption,
        ],
        keywords: ["delete", "drop", "blank"], actionTitle: "Remove pages"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        var remove = Set(
            try StudioPageSelection.pages(run.settings.text("pages"), pageCount: document.pageCount)
        )
        if run.settings.bool("blank") {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                if let image = try? StudioPDF.render(page, dpi: 50), StudioImageOps.isBlank(image) {
                    remove.insert(index)
                }
            }
        }
        guard remove.count < document.pageCount else {
            throw StudioError.nothingToDo("That would remove every page.")
        }
        for index in remove.sorted(by: >) { document.removePage(at: index) }
        let output = run.output(for: run.input, suffix: "edited", ext: "pdf")
        try StudioPDF.write(document, to: output)
        run.note("Removed \(remove.count) page\(remove.count == 1 ? "" : "s").")
        return [output]
    }

    static let reorder = StudioTool(
        id: "pdf.reorder", title: "Reorder pages",
        summary: "Reverse, interleave scanned sides or put pages in a custom order.",
        symbol: "arrow.up.arrow.down", group: .organize, inputs: [.pdf], produces: .kind(.pdf),
        options: [
            .choice(
                "order", "Order",
                [
                    StudioChoice("reverse", "Reverse"), StudioChoice("custom", "Custom"),
                    StudioChoice("interleave", "Interleave duplex scan"),
                ], default: "reverse",
                help:
                    "Interleave takes a scan of all fronts then all backs in reverse and restores reading order."
            ),
            .text(
                "sequence", "New order", placeholder: "3, 1, 2, 4-", default: "",
                help: "Pages you leave out are dropped.", when: .init("order", ["custom"]),
                required: true),
            passwordOption,
        ],
        keywords: ["sort", "reverse", "arrange", "duplex", "organize"], actionTitle: "Reorder"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let count = document.pageCount
        let order: [Int]
        switch run.settings.text("order") {
        case "custom":
            order = try StudioPageSelection.pages(run.settings.text("sequence"), pageCount: count)
        case "interleave":
            order = PDFPageOrder.interleaved(count: count)
        default:
            order = Array((0..<count).reversed())
        }
        let result = PDFDocument()
        for index in order {
            if let page = document.page(at: index)?.copy() as? PDFPage {
                result.insert(page, at: result.pageCount)
            }
        }
        let output = run.output(for: run.input, suffix: "reordered", ext: "pdf")
        try StudioPDF.write(result, to: output)
        return [output]
    }

    static let rotate = StudioTool(
        id: "pdf.rotate", title: "Rotate PDF",
        summary: "Turn all pages or just some of them. Works on many PDFs at once.",
        symbol: "rotate.right", group: .organize, inputs: [.pdf], produces: .kind(.pdf),
        options: [
            .choice(
                "angle", "Rotate",
                [
                    StudioChoice("90", "Right 90°"), StudioChoice("180", "180°"),
                    StudioChoice("270", "Left 90°"),
                ], default: "90"),
            .choice(
                "orientation", "Only",
                [
                    StudioChoice("any", "Every page"), StudioChoice("portrait", "Portrait pages"),
                    StudioChoice("landscape", "Landscape pages"),
                ], default: "any"),
            .pages(),
            passwordOption,
        ],
        keywords: ["turn", "orientation", "landscape", "portrait"], actionTitle: "Rotate"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let angle = Int(run.settings.text("angle")) ?? 90
        let pages = try StudioPageSelection.pages(
            run.settings.text("pages"), pageCount: document.pageCount)
        let orientation = run.settings.text("orientation")
        var turned = 0
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            let size = StudioPDF.displaySize(page)
            if orientation == "portrait", size.width > size.height { continue }
            if orientation == "landscape", size.height >= size.width { continue }
            page.rotation = (StudioPDF.rotation(page) + angle) % 360
            turned += 1
        }
        guard turned > 0 else { throw StudioError.nothingToDo("No pages matched the selection.") }
        let output = run.output(for: run.input, suffix: "rotated", ext: "pdf")
        try StudioPDF.write(document, to: output)
        return [output]
    }

    static let organize = StudioTool(
        id: "pdf.organize", title: "Organize PDF",
        summary: "Sort, rotate, delete, duplicate and insert pages visually.",
        symbol: "square.grid.3x3", group: .organize, inputs: [.pdf], produces: .kind(.pdf),
        style: .editor(.pdf, pdfMode: .organize),
        keywords: ["sort", "arrange", "insert", "delete", "pages"])

    static let nUp = StudioTool(
        id: "pdf.n-up", title: "Pages per sheet",
        summary: "Print-ready layouts with 2, 4, 6, 9 or 16 pages on each sheet.",
        symbol: "square.grid.2x2", group: .organize, inputs: [.pdf], produces: .kind(.pdf),
        options: [
            .choice(
                "layout", "Pages per sheet",
                ["2", "4", "6", "9", "16"].map { StudioChoice($0, $0) }, default: "4"),
            .choice("paper", "Sheet", StudioPaperSize.choices, default: "a4"),
            .toggle("border", "Draw a thin border around each page", default: true),
            .number("margin", "Margin", 0...72, step: 2, default: 18, unit: "pt"),
            passwordOption,
        ],
        keywords: ["n-up", "imposition", "handout", "print", "booklet"], actionTitle: "Arrange"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let perSheet = Int(run.settings.text("layout")) ?? 4
        let paper = StudioPaperSize(rawValue: run.settings.text("paper")) ?? .a4
        let output = run.output(for: run.input, suffix: "\(perSheet)-up", ext: "pdf")
        try PDFImposition.nUp(
            document, perSheet: perSheet, paper: paper.points,
            margin: run.settings.number("margin"), border: run.settings.bool("border"),
            to: output
        ) { run.progress($0) }
        return [output]
    }

    static let resize = StudioTool(
        id: "pdf.page-size", title: "Change page size",
        summary: "Fit every page onto A4, Letter or another paper size.",
        symbol: "arrow.up.left.and.arrow.down.right.rectangle", group: .organize, inputs: [.pdf],
        produces: .kind(.pdf),
        options: [
            .choice("paper", "Paper", StudioPaperSize.choices, default: "a4"),
            .choice(
                "fit", "Fit",
                [StudioChoice("fit", "Fit inside"), StudioChoice("fill", "Fill and crop")],
                default: "fit"),
            .number("margin", "Margin", 0...72, step: 2, default: 0, unit: "pt"),
            passwordOption,
        ],
        keywords: ["scale", "paper", "a4", "letter", "resize"], actionTitle: "Resize pages"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let paper = StudioPaperSize(rawValue: run.settings.text("paper")) ?? .a4
        let output = run.output(for: run.input, suffix: paper.rawValue, ext: "pdf")
        try PDFImposition.resize(
            document, paper: paper.points, fill: run.settings.text("fit") == "fill",
            margin: run.settings.number("margin"), to: output
        ) { run.progress($0) }
        return [output]
    }

    static let crop = StudioTool(
        id: "pdf.crop", title: "Crop PDF",
        summary: "Trim white margins automatically or cut fixed margins from pages.",
        symbol: "crop", group: .edit, inputs: [.pdf], produces: .kind(.pdf),
        options: [
            .choice(
                "mode", "Crop",
                [
                    StudioChoice("auto", "Trim white margins"),
                    StudioChoice("margins", "Fixed margins"),
                ],
                default: "auto"),
            .number(
                "padding", "Keep around content", 0...72, step: 1, default: 12, unit: "pt",
                when: .init("mode", ["auto"])),
            .number(
                "top", "Top", 0...400, step: 1, default: 36, unit: "pt",
                when: .init("mode", ["margins"])),
            .number(
                "bottom", "Bottom", 0...400, step: 1, default: 36, unit: "pt",
                when: .init("mode", ["margins"])),
            .number(
                "left", "Left", 0...400, step: 1, default: 36, unit: "pt",
                when: .init("mode", ["margins"])),
            .number(
                "right", "Right", 0...400, step: 1, default: 36, unit: "pt",
                when: .init("mode", ["margins"])),
            .pages(),
            passwordOption,
        ],
        keywords: ["trim", "margins", "cut"], actionTitle: "Crop"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let pages = try StudioPageSelection.pages(
            run.settings.text("pages"), pageCount: document.pageCount)
        var cropped = 0
        for (step, index) in pages.enumerated() {
            try run.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let box = StudioPDF.cropBox(page)
            let target: CGRect
            if run.settings.text("mode") == "margins" {
                let insets = PDFCropping.pageInsets(
                    top: run.settings.number("top"), bottom: run.settings.number("bottom"),
                    left: run.settings.number("left"), right: run.settings.number("right"),
                    rotation: StudioPDF.rotation(page))
                target = CGRect(
                    x: box.minX + insets.left, y: box.minY + insets.bottom,
                    width: box.width - insets.left - insets.right,
                    height: box.height - insets.top - insets.bottom)
            } else {
                guard let content = try PDFCropping.contentRect(of: page) else { continue }
                let padding = run.settings.number("padding")
                target = content.insetBy(dx: -padding, dy: -padding).intersection(box)
            }
            guard target.width > 8, target.height > 8 else { continue }
            PDFCropping.apply(target, to: page)
            cropped += 1
            run.progress(Double(step + 1) / Double(pages.count))
        }
        guard cropped > 0 else { throw StudioError.nothingToDo("Nothing to crop on these pages.") }
        let output = run.output(for: run.input, suffix: "cropped", ext: "pdf")
        try StudioPDF.write(document, to: output)
        return [output]
    }

    static let cropVisual = StudioTool(
        id: "pdf.crop-area", title: "Crop area",
        summary: "Draw the area to keep on a page and apply it to one page or the whole PDF.",
        symbol: "crop.rotate", group: .edit, inputs: [.pdf], produces: .kind(.pdf),
        style: .editor(.pdf, pdfMode: .crop), keywords: ["select", "region", "trim"])
}

enum PDFPageOrder {
    static func interleaved(count: Int) -> [Int] {
        let fronts = (count + 1) / 2
        var order: [Int] = []
        for index in 0..<fronts {
            order.append(index)
            let back = count - 1 - index
            if back >= fronts { order.append(back) }
        }
        return order
    }
}

public enum PDFCropping {
    public static func pageInsets(
        top: Double, bottom: Double, left: Double, right: Double, rotation: Int
    ) -> (top: Double, bottom: Double, left: Double, right: Double) {
        switch rotation {
        case 90: (top: right, bottom: left, left: top, right: bottom)
        case 180: (top: bottom, bottom: top, left: right, right: left)
        case 270: (top: left, bottom: right, left: bottom, right: top)
        default: (top: top, bottom: bottom, left: left, right: right)
        }
    }

    public static func contentRect(of page: PDFPage) throws -> CGRect? {
        let image = try StudioPDF.render(page, dpi: 72, background: CGColor(gray: 1, alpha: 1))
        guard let unit = StudioImageOps.contentBounds(image) else { return nil }
        let size = StudioPDF.displaySize(page)
        let display = CGRect(
            x: unit.minX * size.width, y: (1 - unit.maxY) * size.height,
            width: unit.width * size.width, height: unit.height * size.height)
        let box = StudioPDF.cropBox(page)
        let toPage = StudioPDF.pageFromDisplay(size: box.size, rotation: StudioPDF.rotation(page))
        return display.applying(toPage).offsetBy(dx: box.minX, dy: box.minY).standardized
    }

    public static func displayRect(_ unit: StudioRect, on page: PDFPage) -> CGRect {
        let size = StudioPDF.displaySize(page)
        let display = CGRect(
            x: unit.x * size.width, y: (1 - unit.y - unit.height) * size.height,
            width: unit.width * size.width, height: unit.height * size.height)
        let box = StudioPDF.cropBox(page)
        let toPage = StudioPDF.pageFromDisplay(size: box.size, rotation: StudioPDF.rotation(page))
        return display.applying(toPage).offsetBy(dx: box.minX, dy: box.minY).standardized
    }

    public static func apply(_ rect: CGRect, to page: PDFPage) {
        page.setBounds(rect, for: .cropBox)
        page.setBounds(rect, for: .mediaBox)
    }
}

enum PDFImposition {
    static func grid(for count: Int, landscape: Bool) -> (columns: Int, rows: Int) {
        switch count {
        case 2: landscape ? (2, 1) : (1, 2)
        case 4: (2, 2)
        case 6: landscape ? (3, 2) : (2, 3)
        case 9: (3, 3)
        case 16: (4, 4)
        default: (1, 1)
        }
    }

    static func nUp(
        _ document: PDFDocument, perSheet: Int, paper: CGSize, margin: Double, border: Bool,
        to url: URL, progress: (Double) -> Void
    ) throws {
        let first = document.page(at: 0).map(StudioPDF.displaySize) ?? paper
        let sourceLandscape = first.width > first.height
        let landscape = perSheet == 2 || perSheet == 6 ? !sourceLandscape : sourceLandscape
        let sheet = landscape ? CGSize(width: paper.height, height: paper.width) : paper
        let layout = grid(for: perSheet, landscape: landscape)
        var box = CGRect(origin: .zero, size: sheet)
        guard
            let context = CGContext(
                url as CFURL, mediaBox: &box, StudioPDF.documentInfo(document) as CFDictionary)
        else { throw StudioError.failed("Could not create \(url.lastPathComponent).") }
        let count = document.pageCount
        let gap = 8.0
        let usable = box.insetBy(dx: margin, dy: margin)
        let cellWidth = (usable.width - gap * Double(layout.columns - 1)) / Double(layout.columns)
        let cellHeight = (usable.height - gap * Double(layout.rows - 1)) / Double(layout.rows)
        var index = 0
        while index < count {
            try Task.checkCancellation()
            context.beginPage(mediaBox: &box)
            for slot in 0..<perSheet where index < count {
                defer { index += 1 }
                guard let page = document.page(at: index), let cgPage = page.pageRef else {
                    continue
                }
                let column = slot % layout.columns
                let row = slot / layout.columns
                let cell = CGRect(
                    x: usable.minX + Double(column) * (cellWidth + gap),
                    y: usable.maxY - Double(row + 1) * cellHeight - Double(row) * gap,
                    width: cellWidth, height: cellHeight)
                draw(cgPage, page: page, into: cell, fill: false, context: context)
                if border {
                    let size = StudioPDF.displaySize(page)
                    let scale = min(cell.width / size.width, cell.height / size.height)
                    let frame = CGRect(
                        x: cell.midX - size.width * scale / 2,
                        y: cell.midY - size.height * scale / 2,
                        width: size.width * scale, height: size.height * scale)
                    context.setStrokeColor(gray: 0.7, alpha: 1)
                    context.setLineWidth(0.5)
                    context.stroke(frame)
                }
            }
            context.endPage()
            progress(Double(index) / Double(count))
        }
        context.closePDF()
    }

    static func resize(
        _ document: PDFDocument, paper: CGSize, fill: Bool, margin: Double, to url: URL,
        progress: (Double) -> Void
    ) throws {
        guard
            let context = CGContext(
                url as CFURL, mediaBox: nil, StudioPDF.documentInfo(document) as CFDictionary)
        else { throw StudioError.failed("Could not create \(url.lastPathComponent).") }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let cgPage = page.pageRef else { continue }
            let size = StudioPDF.displaySize(page)
            let sheet =
                size.width > size.height ? CGSize(width: paper.height, height: paper.width) : paper
            var box = CGRect(origin: .zero, size: sheet)
            context.beginPage(mediaBox: &box)
            draw(
                cgPage, page: page, into: box.insetBy(dx: margin, dy: margin), fill: fill,
                context: context)
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        context.closePDF()
    }

    static func draw(
        _ cgPage: CGPDFPage, page: PDFPage, into cell: CGRect, fill: Bool, context: CGContext
    ) {
        let size = StudioPDF.displaySize(page)
        guard size.width > 0, size.height > 0 else { return }
        let scale =
            fill
            ? max(cell.width / size.width, cell.height / size.height)
            : min(cell.width / size.width, cell.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: cell.midX - drawn.width / 2, y: cell.midY - drawn.height / 2)
        let box = StudioPDF.cropBox(page)
        context.saveGState()
        context.clip(to: cell)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        context.concatenate(
            StudioPDF.pageFromDisplay(size: box.size, rotation: StudioPDF.rotation(page)).inverted()
        )
        context.clip(to: CGRect(origin: .zero, size: box.size))
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(cgPage)
        context.restoreGState()
    }
}
