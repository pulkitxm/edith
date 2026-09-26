import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

enum PDFEditTools {
    static var all: [StudioTool] {
        [
            edit, sign, forms, watermark, pageNumbers, metadata, protect, unlock, redact,
            redactVisual,
        ].map { $0.checkingChoices() }
    }

    static let edit = StudioTool(
        id: "pdf.edit", title: "Edit PDF",
        summary: "Add text, images, shapes, highlights and freehand drawings to a PDF.",
        symbol: "pencil.and.outline", group: .edit, inputs: [.pdf], produces: .kind(.pdf),
        style: .editor(.pdf, pdfMode: .annotate),
        keywords: ["annotate", "text", "draw", "shapes", "comment", "highlight", "markup"])

    static let sign = StudioTool(
        id: "pdf.sign", title: "Sign PDF",
        summary: "Draw, type or import your signature and place it on any page.",
        symbol: "signature", group: .security, inputs: [.pdf], produces: .kind(.pdf),
        style: .editor(.pdf, pdfMode: .sign), keywords: ["signature", "esign", "initials"])

    static let forms = StudioTool(
        id: "pdf.forms", title: "PDF forms",
        summary: "Fill in forms, or add text fields, checkboxes and choice lists to make one.",
        symbol: "list.bullet.rectangle.portrait", group: .edit, inputs: [.pdf],
        produces: .kind(.pdf), style: .editor(.pdf, pdfMode: .forms),
        keywords: ["fill", "fillable", "fields", "checkbox", "form"])

    static let watermark = StudioTool(
        id: "pdf.watermark", title: "Watermark PDF",
        summary:
            "Stamp text or an image over your PDF with the font, opacity and position you choose.",
        symbol: "drop.halffull", group: .edit, inputs: [.pdf],
        options: StudioStamp.options(textDefault: "CONFIDENTIAL") + [
            .choice(
                "layer", "Layer",
                [StudioChoice("over", "Over content"), StudioChoice("under", "Behind content")],
                default: "over"),
            .pages(), PDFOrganizeTools.passwordOption,
        ],
        keywords: ["stamp", "draft", "confidential", "logo", "brand"], actionTitle: "Add watermark"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let stamp = try StudioStamp.from(run.settings)
        let pages = Set(
            try StudioPageSelection.pages(run.settings.text("pages"), pageCount: document.pageCount)
        )
        let output = run.output(for: run.input, suffix: "watermarked", ext: "pdf")
        let draw: (StudioPDF.PageCanvas) throws -> Void = { canvas in
            stamp.draw(in: canvas.context, size: canvas.size)
        }
        let under = run.settings.text("layer") == "under"
        try StudioPDF.rebuild(
            document, to: output, pages: pages, under: under ? draw : nil, over: under ? nil : draw
        ) { run.progress($0) }
        return [output]
    }

    static let pageNumbers = StudioTool(
        id: "pdf.page-numbers", title: "Page numbers",
        summary: "Add page numbers, headers or footers with your own position, text and size.",
        symbol: "number", group: .edit, inputs: [.pdf],
        options: [
            .choice(
                "position", "Position",
                [
                    StudioChoice("bottom", "Bottom center"),
                    StudioChoice("bottom-right", "Bottom right"),
                    StudioChoice("bottom-left", "Bottom left"), StudioChoice("top", "Top center"),
                    StudioChoice("top-right", "Top right"), StudioChoice("top-left", "Top left"),
                ], default: "bottom"),
            .choice(
                "format", "Text",
                [
                    StudioChoice("{n}", "1"), StudioChoice("Page {n}", "Page 1"),
                    StudioChoice("Page {n} of {total}", "Page 1 of 9"),
                    StudioChoice("{n} / {total}", "1 / 9"), StudioChoice("custom", "Custom"),
                ], default: "{n}"),
            .text(
                "custom", "Custom text", placeholder: "{file} · {n} of {total} · {date}",
                default: "{file} · page {n}",
                help: "Use {n}, {total}, {file} and {date}.", when: .init("format", ["custom"])),
            .integer("start", "First number", 0...100_000, default: 1),
            .toggle("skipFirst", "Leave the first page unnumbered", default: false),
            .number("size", "Font size", 6...48, step: 1, default: 11, unit: "pt"),
            .font(default: "Helvetica Neue"),
            .color("color", "Color", default: "#333333"),
            .number("margin", "Distance from edge", 8...96, step: 2, default: 28, unit: "pt"),
            .pages(), PDFOrganizeTools.passwordOption,
        ],
        keywords: ["numbering", "header", "footer", "bates", "pagination"],
        actionTitle: "Add page numbers"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        var pages = Set(
            try StudioPageSelection.pages(run.settings.text("pages"), pageCount: document.pageCount)
        )
        if run.settings.bool("skipFirst") { pages.remove(0) }
        let template =
            run.settings.text("format") == "custom"
            ? run.settings.text("custom") : run.settings.text("format")
        let ordered = pages.sorted()
        let start = run.settings.int("start")
        let skipOffset = run.settings.bool("skipFirst") ? 1 : 0
        let total = document.pageCount - skipOffset + start - 1
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        let font = StudioStamp.font(
            named: run.settings.text("font"), size: run.settings.number("size"), bold: false)
        let color = run.settings.color("color")
        let margin = run.settings.number("margin")
        let position = run.settings.text("position")
        let output = run.output(for: run.input, suffix: "numbered", ext: "pdf")
        try StudioPDF.rebuild(
            document, to: output, pages: pages,
            over: { canvas in
                guard ordered.contains(canvas.index) else { return }
                let number = canvas.index - skipOffset + start
                let text = PDFPageNumbering.render(
                    template, number: number, total: total, file: run.input.studioStem, date: date)
                PDFPageNumbering.draw(
                    text, position: position, margin: margin, font: font, color: color,
                    canvas: canvas)
            }
        ) { run.progress($0) }
        return [output]
    }

    static let metadata = StudioTool(
        id: "pdf.metadata", title: "Edit metadata",
        summary: "Change or remove the title, author, subject and keywords stored in a PDF.",
        symbol: "info.circle", group: .edit, inputs: [.pdf],
        options: [
            .toggle("clear", "Remove all metadata", default: false),
            .text("title", "Title", when: .init("clear", ["off"])),
            .text("author", "Author", when: .init("clear", ["off"])),
            .text("subject", "Subject", when: .init("clear", ["off"])),
            .text(
                "keywords", "Keywords", placeholder: "comma separated",
                when: .init("clear", ["off"])),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["properties", "author", "title", "privacy", "info"], actionTitle: "Save metadata"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        var attributes: [AnyHashable: Any] = [:]
        if !run.settings.bool("clear") {
            attributes = document.documentAttributes ?? [:]
            let fields: [(String, PDFDocumentAttribute)] = [
                ("title", .titleAttribute), ("author", .authorAttribute),
                ("subject", .subjectAttribute),
            ]
            for (key, attribute) in fields {
                let value = run.settings.trimmed(key)
                if !value.isEmpty { attributes[attribute] = value }
            }
            let keywords = run.settings.trimmed("keywords")
            if !keywords.isEmpty {
                attributes[PDFDocumentAttribute.keywordsAttribute] = keywords.split(separator: ",")
                    .map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
            }
        } else {
            attributes[PDFDocumentAttribute.creatorAttribute] = ""
            attributes[PDFDocumentAttribute.producerAttribute] = ""
        }
        document.documentAttributes = attributes
        let output = run.output(for: run.input, suffix: "metadata", ext: "pdf")
        try StudioPDF.write(document, to: output)
        return [output]
    }

    static let protect = StudioTool(
        id: "pdf.protect", title: "Protect PDF",
        summary: "Encrypt a PDF with a password and choose what others may do with it.",
        symbol: "lock.doc", group: .security, inputs: [.pdf],
        options: [
            .password("userPassword", "Password to open", required: true),
            .password(
                "ownerPassword", "Owner password",
                help: "Optional. Needed to change permissions later. Defaults to a random one."),
            .toggle("allowPrinting", "Allow printing", default: true),
            .toggle("allowCopying", "Allow copying text and images", default: false),
            .toggle("allowEditing", "Allow editing and comments", default: false),
            .password(
                "password", "Current password", help: "Only needed when the PDF is already locked."),
        ],
        keywords: ["encrypt", "password", "lock", "secure", "permissions"], actionTitle: "Protect"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let user = run.settings.text("userPassword")
        var owner = run.settings.text("ownerPassword")
        if owner.isEmpty { owner = UUID().uuidString }
        var granted: [PDFAccessPermissions] = []
        if run.settings.bool("allowPrinting") {
            granted += [.allowsLowQualityPrinting, .allowsHighQualityPrinting]
        }
        if run.settings.bool("allowCopying") {
            granted += [.allowsContentCopying, .allowsContentAccessibility]
        }
        if run.settings.bool("allowEditing") {
            granted += [
                .allowsCommenting, .allowsFormFieldEntry, .allowsDocumentChanges,
                .allowsDocumentAssembly,
            ]
        }
        let permissions = granted.reduce(UInt(0)) { $0 | $1.rawValue }
        let output = run.output(for: run.input, suffix: "protected", ext: "pdf")
        try StudioPDF.write(
            document, to: output,
            options: [
                .userPasswordOption: user, .ownerPasswordOption: owner,
                .accessPermissionsOption: NSNumber(value: permissions),
            ])
        guard let check = PDFDocument(url: output), check.isEncrypted else {
            throw StudioError.failed("The PDF could not be encrypted.")
        }
        return [output]
    }

    static let unlock = StudioTool(
        id: "pdf.unlock", title: "Unlock PDF",
        summary: "Remove the password and restrictions from a PDF you have the password for.",
        symbol: "lock.open", group: .security, inputs: [.pdf],
        options: [
            .password(
                "password", "Password",
                help: "Leave empty when the PDF opens without a password but has restrictions.")
        ],
        keywords: ["decrypt", "password", "remove", "restrictions"], actionTitle: "Unlock"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        guard document.isEncrypted || document.isLocked else {
            throw StudioError.nothingToDo("\(run.input.lastPathComponent) is not protected.")
        }
        let copy = StudioPDF.fresh(from: document)
        copy.documentAttributes = document.documentAttributes
        let output = run.output(for: run.input, suffix: "unlocked", ext: "pdf")
        try StudioPDF.write(copy, to: output)
        guard let check = PDFDocument(url: output), !check.isEncrypted else {
            throw StudioError.failed("The protection could not be removed.")
        }
        return [output]
    }

    static let redact = StudioTool(
        id: "pdf.redact", title: "Redact PDF",
        summary: "Find and permanently black out names, emails, numbers or any words you choose.",
        symbol: "rectangle.fill.badge.xmark", group: .security, inputs: [.pdf],
        options: [
            .longText(
                "terms", "Words to redact", placeholder: "One per line or comma separated",
                default: "", help: "Matches ignore case."),
            .toggle("emails", "Email addresses", default: true),
            .toggle("phones", "Phone numbers", default: true),
            .toggle("cards", "Card and account numbers", default: false),
            .toggle("urls", "Web links", default: false),
            .toggle("dates", "Dates", default: false),
            .color("fill", "Box color", default: "#000000"),
            .toggle(
                "searchable", "Keep the rest of the text searchable", default: true,
                help: "Redacted pages are flattened, then read again with text recognition."),
            .toggle("scrubMetadata", "Remove document metadata", default: true),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["black out", "censor", "hide", "privacy", "gdpr", "pii", "remove text"],
        actionTitle: "Redact"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let terms = PDFRedaction.terms(from: run.settings.text("terms"))
        var patterns: [PDFRedaction.Pattern] = []
        if run.settings.bool("emails") { patterns.append(.email) }
        if run.settings.bool("phones") { patterns.append(.phone) }
        if run.settings.bool("cards") { patterns.append(.card) }
        if run.settings.bool("urls") { patterns.append(.url) }
        if run.settings.bool("dates") { patterns.append(.date) }
        guard !terms.isEmpty || !patterns.isEmpty else {
            throw StudioError.invalidOption("words to redact", "enter words or pick a pattern")
        }
        let marks = PDFRedaction.find(terms: terms, patterns: patterns, in: document)
        guard !marks.isEmpty else {
            throw StudioError.nothingToDo("Nothing in this PDF matched what you asked to redact.")
        }
        let output = run.output(for: run.input, suffix: "redacted", ext: "pdf")
        try await PDFRedaction.apply(
            marks, to: document, fill: run.settings.color("fill"),
            searchable: run.settings.bool("searchable"),
            scrubMetadata: run.settings.bool("scrubMetadata"), output: output,
            scrub: PDFRedaction.scrubber(terms: terms, patterns: patterns)
        ) { run.progress($0) }
        let count = marks.values.reduce(0) { $0 + $1.count }
        run.note(
            "Redacted \(count) match\(count == 1 ? "" : "es") on \(marks.count) page\(marks.count == 1 ? "" : "s")."
        )
        return [output]
    }

    static let redactVisual = StudioTool(
        id: "pdf.redact-areas", title: "Redact areas",
        summary:
            "Draw boxes over anything, including images and signatures, then remove it for good.",
        symbol: "rectangle.dashed.badge.record", group: .security, inputs: [.pdf],
        produces: .kind(.pdf), style: .editor(.pdf, pdfMode: .redact),
        keywords: ["black out", "censor", "hide", "manual"])
}

enum PDFPageNumbering {
    static func render(_ template: String, number: Int, total: Int, file: String, date: String)
        -> String
    {
        template.replacingOccurrences(of: "{n}", with: String(number))
            .replacingOccurrences(of: "{total}", with: String(total))
            .replacingOccurrences(of: "{file}", with: file)
            .replacingOccurrences(of: "{date}", with: date)
    }

    static func draw(
        _ text: String, position: String, margin: Double, font: CTFont, color: StudioColor,
        canvas: StudioPDF.PageCanvas
    ) {
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color.cgColor])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let size = canvas.size
        let x: CGFloat
        if position.hasSuffix("left") {
            x = margin
        } else if position.hasSuffix("right") {
            x = size.width - margin - width
        } else {
            x = (size.width - width) / 2
        }
        let y = position.hasPrefix("top") ? size.height - margin - CTFontGetAscent(font) : margin
        canvas.context.textMatrix = .identity
        canvas.context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, canvas.context)
    }
}
