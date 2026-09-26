import AppKit
import Foundation

enum DOCXReader {
    static func read(_ url: URL) throws -> [DocumentSection] {
        let parts: [String: Data]
        do {
            parts = try OOXMLPackage.read(url)
        } catch {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        let main = mainPart(parts) ?? "word/document.xml"
        guard let data = parts[main], let tree = XMLTree.parse(data, strict: true),
            let body = tree.child("body")
        else { throw StudioError.unreadable(url.lastPathComponent) }
        return DOCXBuilder(parts: parts, main: main).sections(body)
    }

    static func mainPart(_ parts: [String: Data]) -> String? {
        guard let data = parts["_rels/.rels"] else { return nil }
        let collector = ElementCollector(names: ["Relationship"])
        collector.run(data)
        let target = collector.elements.first {
            $0["Type"]?.hasSuffix("/officeDocument") == true
        }?["Target"]
        return target.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    }
}

struct DOCXStyles {
    struct Style {
        let id: String
        let type: String
        let name: String
        let basedOn: String?
        let paragraph: XMLTree?
        let run: XMLTree?
        let table: XMLTree?
    }

    var styles: [String: Style] = [:]
    var defaultParagraph: String?
    var defaultCharacter: String?
    var documentRun: XMLTree?
    var documentParagraph: XMLTree?

    init(_ data: Data?) {
        guard let data, let tree = XMLTree.parse(data) else { return }
        documentRun = tree.path("docDefaults", "rPrDefault", "rPr")
        documentParagraph = tree.path("docDefaults", "pPrDefault", "pPr")
        for node in tree.all("style") {
            guard let id = node.attribute("styleId") else { continue }
            let type = node.attribute("type") ?? "paragraph"
            styles[id] = Style(
                id: id, type: type, name: node.child("name")?.attribute("val") ?? id,
                basedOn: node.child("basedOn")?.attribute("val"), paragraph: node.child("pPr"),
                run: node.child("rPr"), table: node.child("tblPr"))
            if DOCXBuilder.flag(node.attribute("default")) == true {
                if type == "paragraph" { defaultParagraph = id }
                if type == "character" { defaultCharacter = id }
            }
        }
    }

    func chain(_ id: String?) -> [Style] {
        var result: [Style] = []
        var current = id
        var seen = Set<String>()
        while let key = current, let style = styles[key], seen.insert(key).inserted {
            result.insert(style, at: 0)
            current = style.basedOn
        }
        return result
    }
}

struct DOCXNumbering {
    struct Level {
        var format = "decimal"
        var text = "%1."
        var start = 1
        var paragraph: XMLTree?
        var legal = false
    }

    var abstracts: [String: [Int: Level]] = [:]
    var instances: [String: (abstract: String, starts: [Int: Int])] = [:]

    init(_ data: Data?) {
        guard let data, let tree = XMLTree.parse(data) else { return }
        for abstract in tree.all("abstractNum") {
            guard let id = abstract.attribute("abstractNumId") else { continue }
            var levels: [Int: Level] = [:]
            for node in abstract.all("lvl") {
                guard let index = node.attribute("ilvl").flatMap(Int.init) else { continue }
                levels[index] = Self.level(node, base: Level())
            }
            abstracts[id] = levels
        }
        for num in tree.all("num") {
            guard let id = num.attribute("numId"),
                let abstract = num.child("abstractNumId")?.attribute("val")
            else { continue }
            var starts: [Int: Int] = [:]
            for override in num.all("lvlOverride") {
                guard let index = override.attribute("ilvl").flatMap(Int.init) else { continue }
                if let start = override.child("startOverride")?.number("val") {
                    starts[index] = Int(start)
                }
                if let node = override.child("lvl") {
                    var levels = abstracts[id + "#override"] ?? abstracts[abstract] ?? [:]
                    levels[index] = Self.level(node, base: levels[index] ?? Level())
                    abstracts[id + "#override"] = levels
                }
            }
            let key = abstracts[id + "#override"] != nil ? id + "#override" : abstract
            instances[id] = (key, starts)
        }
    }

    static func level(_ node: XMLTree, base: Level) -> Level {
        var level = base
        if let format = node.child("numFmt")?.attribute("val") { level.format = format }
        if let text = node.child("lvlText")?.attribute("val") { level.text = text }
        if let start = node.child("start")?.number("val") { level.start = Int(start) }
        if let paragraph = node.child("pPr") { level.paragraph = paragraph }
        if node.child("isLgl") != nil { level.legal = true }
        return level
    }
}

struct DOCXRunFormat {
    var font: String?
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var color: NSColor?
    var background: NSColor?
    var vertical: String?
    var caps: Bool?
    var hidden: Bool?

    mutating func apply(_ node: XMLTree?, theme: DOCXTheme) {
        guard let node else { return }
        if let fonts = node.child("rFonts") {
            if let name = fonts.attribute("ascii") ?? fonts.attribute("hAnsi") {
                font = name
            } else if let themed = fonts.attribute("asciiTheme") ?? fonts.attribute("hAnsiTheme"),
                let name = theme.font(themed)
            {
                font = name
            }
        }
        if let value = node.child("sz")?.number("val") { size = CGFloat(value) / 2 }
        if let value = node.child("b") { bold = DOCXBuilder.flag(value.attribute("val")) ?? true }
        if let value = node.child("i") { italic = DOCXBuilder.flag(value.attribute("val")) ?? true }
        if let value = node.child("u") {
            let kind = value.attribute("val") ?? "single"
            underline = kind != "none" && DOCXBuilder.flag(kind) != false
        }
        if let value = node.child("strike") ?? node.child("dstrike") {
            strike = DOCXBuilder.flag(value.attribute("val")) ?? true
        }
        if let value = node.child("color")?.attribute("val") {
            color = value == "auto" ? NSColor.black : PresentationRenderer.hexColor(value)
        }
        if let value = node.child("highlight")?.attribute("val") {
            background = DOCXBuilder.highlight[value]
        }
        if let fill = node.child("shd")?.attribute("fill"), fill != "auto" {
            background = PresentationRenderer.hexColor(fill) ?? background
        }
        if let value = node.child("vertAlign")?.attribute("val") { vertical = value }
        if let value = node.child("caps") {
            caps = DOCXBuilder.flag(value.attribute("val")) ?? true
        }
        if let value = node.child("vanish") {
            hidden = DOCXBuilder.flag(value.attribute("val")) ?? true
        }
    }
}

struct DOCXParagraphFormat {
    var alignment: String?
    var left: CGFloat?
    var right: CGFloat?
    var firstLine: CGFloat?
    var before: CGFloat?
    var after: CGFloat?
    var line: CGFloat?
    var lineRule: String?
    var bidi: Bool?
    var numberID: String?
    var level: Int?
    var outline: Int?
    var pageBreakBefore: Bool?
    var contextual: Bool?
    var tabs: [NSTextTab]?

    mutating func apply(_ node: XMLTree?) {
        guard let node else { return }
        if let value = node.child("jc")?.attribute("val") { alignment = value }
        if let indent = node.child("ind") {
            if let value = indent.number("left") ?? indent.number("start") {
                left = DOCXBuilder.points(value)
            }
            if let value = indent.number("right") ?? indent.number("end") {
                right = DOCXBuilder.points(value)
            }
            if let value = indent.number("hanging") {
                firstLine = -DOCXBuilder.points(value)
            } else if let value = indent.number("firstLine") ?? indent.number("first-line") {
                firstLine = DOCXBuilder.points(value)
            }
        }
        if let spacing = node.child("spacing") {
            if DOCXBuilder.flag(spacing.attribute("beforeAutospacing")) == true {
                before = 14
            } else if let value = spacing.number("before") {
                before = DOCXBuilder.points(value)
            }
            if DOCXBuilder.flag(spacing.attribute("afterAutospacing")) == true {
                after = 14
            } else if let value = spacing.number("after") {
                after = DOCXBuilder.points(value)
            }
            if let value = spacing.number("line") {
                line = CGFloat(value)
                lineRule = spacing.attribute("lineRule") ?? "auto"
            }
        }
        if let value = node.child("bidi") {
            bidi = DOCXBuilder.flag(value.attribute("val")) ?? true
        }
        if let numbering = node.child("numPr") {
            if let id = numbering.child("numId")?.attribute("val") { numberID = id }
            if let value = numbering.child("ilvl")?.number("val") { level = Int(value) }
        }
        if let value = node.child("outlineLvl")?.number("val") { outline = Int(value) }
        if let value = node.child("pageBreakBefore") {
            pageBreakBefore = DOCXBuilder.flag(value.attribute("val")) ?? true
        }
        if let value = node.child("contextualSpacing") {
            contextual = DOCXBuilder.flag(value.attribute("val")) ?? true
        }
        if let tabs = node.child("tabs") {
            self.tabs = tabs.all("tab").compactMap { tab -> NSTextTab? in
                guard tab.attribute("val") != "clear", let position = tab.number("pos") else {
                    return nil
                }
                let location = DOCXBuilder.points(position)
                switch tab.attribute("val") {
                case "center": return NSTextTab(textAlignment: .center, location: location)
                case "right", "end": return NSTextTab(textAlignment: .right, location: location)
                case "decimal":
                    return NSTextTab(
                        textAlignment: .right, location: location,
                        options: [.columnTerminators: CharacterSet(charactersIn: ".,")])
                default: return NSTextTab(textAlignment: .left, location: location)
                }
            }
        }
    }
}

struct DOCXTheme {
    var major: String?
    var minor: String?

    init(_ data: Data?) {
        guard let data, let tree = XMLTree.parse(data) else { return }
        major = tree.first("majorFont")?.child("latin")?.attribute("typeface")
        minor = tree.first("minorFont")?.child("latin")?.attribute("typeface")
    }

    func font(_ reference: String) -> String? {
        reference.lowercased().hasPrefix("major") ? major : minor
    }
}

final class DOCXBuilder {
    struct Field {
        var instruction = ""
        var separated = false
        var placeholder = false
    }

    struct Inline {
        var links: [URL?] = []
        var fields: [Field] = []
        var boxes: [XMLTree] = []
        var inCell = false
    }

    let parts: [String: Data]
    let main: String
    let styles: DOCXStyles
    let numbering: DOCXNumbering
    let theme: DOCXTheme
    var relationshipCache: [String: [String: String]] = [:]
    var counters: [String: [Int: Int]] = [:]
    var startedInstances = Set<String>()
    var notes: [(number: Int, node: XMLTree, part: String)] = []
    var noteTrees: [String: [String: XMLTree]] = [:]
    var currentNote: Int?
    var previousStyle: String?

    static let fieldKey = TextPaginator.fieldKey
    static let highlight: [String: NSColor] = [
        "yellow": "FFFF00", "green": "00FF00", "cyan": "00FFFF", "magenta": "FF00FF",
        "blue": "0000FF", "red": "FF0000", "darkBlue": "000080", "darkCyan": "008080",
        "darkGreen": "008000", "darkMagenta": "800080", "darkRed": "800000",
        "darkYellow": "808000", "darkGray": "808080", "lightGray": "C0C0C0", "black": "000000",
        "white": "FFFFFF",
    ].compactMapValues(PresentationRenderer.hexColor)

    init(parts: [String: Data], main: String) {
        self.parts = parts
        self.main = main
        let relationships = Self.relationships(parts, for: main)
        func related(_ type: String, fallback: String) -> Data? {
            let target = relationships.first { $0.type.hasSuffix("/" + type) }?.target
            return parts[target.map { OOXMLRelationships.resolve($0, from: main) } ?? fallback]
        }
        styles = DOCXStyles(related("styles", fallback: "word/styles.xml"))
        numbering = DOCXNumbering(related("numbering", fallback: "word/numbering.xml"))
        theme = DOCXTheme(related("theme", fallback: "word/theme/theme1.xml"))
        for (type, fallback, element) in [
            ("footnotes", "word/footnotes.xml", "footnote"),
            ("endnotes", "word/endnotes.xml", "endnote"),
        ] {
            guard let data = related(type, fallback: fallback), let tree = XMLTree.parse(data)
            else { continue }
            var map: [String: XMLTree] = [:]
            for note in tree.all(element) {
                if let id = note.attribute("id") { map[id] = note }
            }
            noteTrees[element] = map
        }
    }

    static func relationships(_ parts: [String: Data], for part: String) -> [(
        id: String, type: String, target: String, external: Bool
    )] {
        guard let data = parts[PresentationRenderer.relsPath(part)] else { return [] }
        let collector = ElementCollector(names: ["Relationship"])
        collector.run(data)
        return collector.elements.compactMap { element in
            guard let id = element["Id"], let target = element["Target"] else { return nil }
            return (id, element["Type"] ?? "", target, element["TargetMode"] == "External")
        }
    }

    func targets(for part: String) -> [String: String] {
        if let cached = relationshipCache[part] { return cached }
        var map: [String: String] = [:]
        for relationship in Self.relationships(parts, for: part) {
            map[relationship.id] =
                relationship.external
                ? relationship.target : OOXMLRelationships.resolve(relationship.target, from: part)
        }
        relationshipCache[part] = map
        return map
    }

    static func flag(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "0", "false", "off", "none": return false
        default: return true
        }
    }

    static func points(_ twips: Double) -> CGFloat { CGFloat(twips) / 20 }

    func sections(_ body: XMLTree) -> [DocumentSection] {
        var groups: [(nodes: [XMLTree], properties: XMLTree?)] = []
        var current: [XMLTree] = []
        var final: XMLTree?
        for node in body.children {
            if node.name == "sectPr" {
                final = node
                continue
            }
            current.append(node)
            if node.name == "p", let properties = node.path("pPr", "sectPr") {
                groups.append((current, properties))
                current = []
            }
        }
        groups.append((current, final))
        var result: [DocumentSection] = []
        var headers: [String: NSAttributedString] = [:]
        for group in groups {
            let setup = pageSetup(group.properties)
            let text = NSMutableAttributedString()
            blocks(group.nodes, part: main, into: text, cells: [], width: setup.content.width)
            for reference in group.properties?.children ?? [] {
                guard reference.name == "headerReference" || reference.name == "footerReference",
                    let id = reference.attribute("id")
                else { continue }
                let kind = reference.name == "headerReference" ? "header" : "footer"
                let type = reference.attribute("type") ?? "default"
                headers["\(kind)-\(type)"] = headerFooter(id, width: setup.content.width)
            }
            let titlePage = DOCXBuilder.flag(group.properties?.child("titlePg")?.attribute("val"))
            var section = DocumentSection(text: text, setup: setup)
            section.header = headers["header-default"]
            section.footer = headers["footer-default"]
            if titlePage == true
                || (group.properties?.child("titlePg") != nil && titlePage != false)
            {
                section.distinctFirstPage = true
                section.firstHeader = headers["header-first"]
                section.firstFooter = headers["footer-first"]
            }
            let margin = group.properties?.child("pgMar")
            section.headerDistance = margin?.number("header").map(Self.points) ?? 36
            section.footerDistance = margin?.number("footer").map(Self.points) ?? 36
            let continuous = group.properties?.child("type")?.attribute("val") == "continuous"
            if continuous, let previous = result.last, previous.setup.paper == setup.paper {
                let merged = NSMutableAttributedString(attributedString: previous.text)
                merged.append(text)
                result[result.count - 1].text = merged
            } else if text.length > 0 || result.isEmpty {
                result.append(section)
            }
        }
        appendNotes(to: &result)
        return result
    }

    func appendNotes(to sections: inout [DocumentSection]) {
        guard !notes.isEmpty, let last = sections.indices.last else { return }
        let text = NSMutableAttributedString(attributedString: sections[last].text)
        let rule = NSMutableParagraphStyle()
        rule.paragraphSpacingBefore = 12
        text.append(
            NSAttributedString(
                string: String(repeating: "\u{2500}", count: 12) + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray,
                    .paragraphStyle: rule,
                ]))
        let width = sections[last].setup.content.width
        for note in notes {
            currentNote = note.number
            blocks(note.node.children, part: note.part, into: text, cells: [], width: width)
        }
        currentNote = nil
        sections[last].text = text
    }

    func pageSetup(_ properties: XMLTree?) -> DocumentPageSetup {
        let size = properties?.child("pgSz")
        var width = size?.number("w").map(Self.points) ?? 612
        var height = size?.number("h").map(Self.points) ?? 792
        if size?.attribute("orient") == "landscape", width < height { swap(&width, &height) }
        let margin = properties?.child("pgMar")
        func edge(_ name: String) -> CGFloat {
            max(0, margin?.number(name).map(Self.points) ?? 72)
        }
        return DocumentPageSetup(
            paper: CGSize(width: max(72, width), height: max(72, height)),
            margins: NSEdgeInsets(
                top: edge("top"), left: edge("left"), bottom: edge("bottom"), right: edge("right")
            ))
    }

    func headerFooter(_ id: String, width: CGFloat) -> NSAttributedString? {
        guard let path = targets(for: main)[id], let data = parts[path],
            let tree = XMLTree.parse(data)
        else { return nil }
        let text = NSMutableAttributedString()
        blocks(tree.children, part: path, into: text, cells: [], width: width)
        while text.length > 0, text.string.hasSuffix("\n") {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        return text.length > 0 ? text : nil
    }

    func blocks(
        _ nodes: [XMLTree], part: String, into output: NSMutableAttributedString,
        cells: [NSTextBlock], width: CGFloat
    ) {
        for node in nodes {
            switch node.name {
            case "p": paragraph(node, part: part, into: output, cells: cells, width: width)
            case "tbl": table(node, part: part, into: output, cells: cells, width: width)
            case "sdt":
                blocks(
                    node.child("sdtContent")?.children ?? [], part: part, into: output,
                    cells: cells, width: width)
            case "customXml", "ins", "moveTo", "txbxContent":
                blocks(node.children, part: part, into: output, cells: cells, width: width)
            case "AlternateContent":
                blocks(
                    node.child("Choice")?.children ?? node.child("Fallback")?.children ?? [],
                    part: part, into: output, cells: cells, width: width)
            default: continue
            }
        }
    }

    func paragraph(
        _ node: XMLTree, part: String, into output: NSMutableAttributedString,
        cells: [NSTextBlock], width: CGFloat
    ) {
        let properties = node.child("pPr")
        let styleID = properties?.child("pStyle")?.attribute("val") ?? styles.defaultParagraph
        let chain = styles.chain(styleID)
        var format = DOCXParagraphFormat()
        format.apply(styles.documentParagraph)
        for style in chain { format.apply(style.paragraph) }
        var direct = DOCXParagraphFormat()
        direct.apply(properties)
        let numberID = direct.numberID ?? format.numberID
        let levelIndex = direct.level ?? format.level ?? 0
        var level: DOCXNumbering.Level?
        if let numberID, numberID != "0", let instance = numbering.instances[numberID] {
            level = numbering.abstracts[instance.abstract]?[levelIndex]
            format.apply(level?.paragraph)
        }
        format.apply(properties)
        var runBase = DOCXRunFormat()
        runBase.apply(styles.documentRun, theme: theme)
        for style in chain { runBase.apply(style.run, theme: theme) }
        var markFormat = runBase
        markFormat.apply(properties?.child("rPr"), theme: theme)

        if format.pageBreakBefore == true, cells.isEmpty, output.length > 0 {
            output.append(NSAttributedString(string: "\u{0C}", attributes: attributes(markFormat)))
        }
        let start = output.length
        var markerFormat: NSTextList.MarkerFormat?
        if let level, let numberID, let instance = numbering.instances[numberID],
            let marker = marker(
                level: level, index: levelIndex, instance: numberID, abstract: instance.abstract,
                starts: instance.starts)
        {
            markerFormat = marker.format
            if !marker.text.isEmpty {
                output.append(
                    NSAttributedString(
                        string: marker.text + "\t", attributes: attributes(markFormat)))
            }
        }
        var state = Inline()
        state.inCell = !cells.isEmpty
        inline(node.children, part: part, base: runBase, into: output, state: &state, width: width)
        output.append(NSAttributedString(string: "\n", attributes: attributes(markFormat)))
        let range = NSRange(location: start, length: output.length - start)
        let style = paragraphStyle(
            format, cells: cells, listDepth: markerFormat == nil ? 0 : levelIndex + 1,
            marker: markerFormat, styleID: styleID)
        output.addAttribute(.paragraphStyle, value: style, range: range)
        output.addAttribute(
            DocumentMarkdown.headingKey, value: headingLevel(format, chain: chain), range: range)
        previousStyle = styleID
        if !state.boxes.isEmpty {
            blocks(state.boxes, part: part, into: output, cells: cells, width: width)
        }
    }

    func headingLevel(_ format: DOCXParagraphFormat, chain: [DOCXStyles.Style]) -> Int {
        if let outline = format.outline, outline < 9 { return min(outline + 1, 6) }
        guard let style = chain.last else { return 0 }
        let name = style.name.lowercased()
        if name == "title" { return 1 }
        if name.hasPrefix("heading "), let value = Int(name.dropFirst(8)), value > 0 {
            return min(value, 6)
        }
        return 0
    }

    func paragraphStyle(
        _ format: DOCXParagraphFormat, cells: [NSTextBlock], listDepth: Int,
        marker: NSTextList.MarkerFormat?, styleID: String?
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let rtl = format.bidi == true
        if rtl { style.baseWritingDirection = .rightToLeft }
        switch format.alignment {
        case "center": style.alignment = .center
        case "right", "end": style.alignment = rtl ? .left : .right
        case "both", "distribute", "justify": style.alignment = .justified
        default: style.alignment = rtl ? .right : .left
        }
        let left = format.left ?? 0
        style.headIndent = max(0, left)
        style.firstLineHeadIndent = max(0, left + (format.firstLine ?? 0))
        if let right = format.right, right > 0 { style.tailIndent = -right }
        var before = format.before ?? 0
        var after = format.after ?? 0
        if format.contextual == true, styleID != nil, styleID == previousStyle {
            before = 0
        }
        if format.contextual == true { after = min(after, 2) }
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        if let line = format.line, line > 0 {
            switch format.lineRule {
            case "exact":
                style.minimumLineHeight = line / 20
                style.maximumLineHeight = line / 20
            case "atLeast":
                style.minimumLineHeight = line / 20
            default:
                style.lineHeightMultiple = max(0.5, line / 240)
            }
        }
        var tabs = format.tabs ?? []
        if listDepth > 0 {
            tabs.append(NSTextTab(textAlignment: .left, location: max(0, left)))
            let list = NSTextList(markerFormat: marker ?? .decimal, options: 0)
            style.textLists = Array(repeating: list, count: listDepth)
        }
        style.tabStops = tabs.sorted { $0.location < $1.location }
        style.defaultTabInterval = 36
        style.textBlocks = cells
        return style
    }

    func marker(
        level: DOCXNumbering.Level, index: Int, instance: String, abstract: String,
        starts: [Int: Int]
    ) -> (text: String, format: NSTextList.MarkerFormat)? {
        guard level.format != "none" || !level.text.isEmpty else { return nil }
        if startedInstances.insert(instance).inserted, !starts.isEmpty {
            for (key, value) in starts { counters[abstract, default: [:]][key] = value - 1 }
        }
        let levels = numbering.abstracts[abstract] ?? [:]
        var values = counters[abstract] ?? [:]
        values[index] = (values[index] ?? (level.start - 1)) + 1
        for key in values.keys where key > index { values[key] = nil }
        counters[abstract] = values
        if level.format == "bullet" {
            return (Self.bullet(level.text), .disc)
        }
        var text = level.text
        for depth in (0...8).reversed() where text.contains("%\(depth + 1)") {
            let info = levels[depth] ?? DOCXNumbering.Level()
            let value = values[depth] ?? info.start
            let format = level.legal ? "decimal" : info.format
            text = text.replacingOccurrences(
                of: "%\(depth + 1)", with: Self.number(value, format: format))
        }
        let marker: NSTextList.MarkerFormat
        switch level.format {
        case "lowerLetter": marker = .lowercaseAlpha
        case "upperLetter": marker = .uppercaseAlpha
        case "lowerRoman": marker = .lowercaseRoman
        case "upperRoman": marker = .uppercaseRoman
        case "none": marker = .disc
        default: marker = .decimal
        }
        return (text, marker)
    }

    static func bullet(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        switch scalar.value {
        case 0xF0B7, 0xF06C, 0xF09F: return "\u{2022}"
        case 0xF0A7, 0xF06E: return "\u{25AA}"
        case 0xF0D8: return "\u{27A2}"
        case 0xF0FC: return "\u{2713}"
        case 0xF076: return "\u{2756}"
        case 0xF000...0xF0FF: return "\u{2022}"
        default: return text == "o" ? "\u{25E6}" : text
        }
    }

    static func number(_ value: Int, format: String) -> String {
        switch format {
        case "lowerLetter": return letters(value).lowercased()
        case "upperLetter": return letters(value)
        case "lowerRoman": return roman(value).lowercased()
        case "upperRoman": return roman(value)
        case "decimalZero": return value < 10 ? "0\(value)" : "\(value)"
        case "ordinal": return ordinal(value)
        case "none": return ""
        default: return "\(value)"
        }
    }

    static func letters(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let letter = String(UnicodeScalar(UInt8(65 + (value - 1) % 26)))
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    static func roman(_ value: Int) -> String {
        guard value > 0 && value < 4000 else { return "\(value)" }
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
            (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = value
        var result = ""
        for (amount, symbol) in table {
            while remaining >= amount {
                result += symbol
                remaining -= amount
            }
        }
        return result
    }

    static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 100, value % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }

    func inline(
        _ nodes: [XMLTree], part: String, base: DOCXRunFormat,
        into output: NSMutableAttributedString, state: inout Inline, width: CGFloat
    ) {
        for node in nodes {
            switch node.name {
            case "r":
                run(node, part: part, base: base, into: output, state: &state, width: width)
            case "hyperlink":
                let target = node.attribute("id").flatMap { targets(for: part)[$0] }
                state.links.append(target.flatMap(URL.init(string:)))
                inline(
                    node.children, part: part, base: base, into: output, state: &state,
                    width: width)
                state.links.removeLast()
            case "fldSimple":
                let instruction = node.attribute("instr") ?? ""
                if let field = Self.pageField(instruction) {
                    output.append(placeholder(field, format: base))
                    continue
                }
                state.links.append(Self.fieldLink(instruction))
                inline(
                    node.children, part: part, base: base, into: output, state: &state,
                    width: width)
                state.links.removeLast()
            case "ins", "moveTo", "smartTag", "customXml", "dir", "bdo":
                inline(
                    node.children, part: part, base: base, into: output, state: &state,
                    width: width)
            case "sdt":
                inline(
                    node.child("sdtContent")?.children ?? [], part: part, base: base,
                    into: output, state: &state, width: width)
            case "AlternateContent":
                inline(
                    node.child("Choice")?.children ?? node.child("Fallback")?.children ?? [],
                    part: part, base: base, into: output, state: &state, width: width)
            case "oMath", "oMathPara":
                let text = node.descendants("t").map(\.text).joined()
                output.append(NSAttributedString(string: text, attributes: attributes(base)))
            default:
                continue
            }
        }
    }

    static func pageField(_ instruction: String) -> String? {
        let word = instruction.trimmingCharacters(in: .whitespaces).split(separator: " ").first
            .map { $0.uppercased() }
        switch word {
        case "PAGE": return "PAGE"
        case "NUMPAGES", "SECTIONPAGES": return "NUMPAGES"
        default: return nil
        }
    }

    static func fieldLink(_ instruction: String) -> URL? {
        let trimmed = instruction.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("HYPERLINK"),
            let open = trimmed.firstIndex(of: "\"")
        else { return nil }
        let rest = trimmed[trimmed.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<close]))
    }

    func placeholder(_ field: String, format: DOCXRunFormat) -> NSAttributedString {
        var attributes = attributes(format)
        attributes[Self.fieldKey] = field
        return NSAttributedString(string: "0", attributes: attributes)
    }

    func run(
        _ node: XMLTree, part: String, base: DOCXRunFormat,
        into output: NSMutableAttributedString, state: inout Inline, width: CGFloat
    ) {
        var format = base
        let properties = node.child("rPr")
        let characterStyle = properties?.child("rStyle")?.attribute("val") ?? nil
        for style in styles.chain(characterStyle) { format.apply(style.run, theme: theme) }
        format.apply(properties, theme: theme)
        content(
            node.children, part: part, format: format, into: output, state: &state, width: width)
    }

    func content(
        _ children: [XMLTree], part: String, format: DOCXRunFormat,
        into output: NSMutableAttributedString, state: inout Inline, width: CGFloat
    ) {
        var attributes = attributes(format)
        if let link = state.links.last(where: { $0 != nil }) ?? nil {
            attributes[.link] = link
        }
        let visible = format.hidden != true
        func showing() -> Bool {
            state.fields.allSatisfy { $0.separated && !$0.placeholder }
        }
        func append(_ text: String) {
            guard visible, showing(), !text.isEmpty else { return }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        for child in children {
            switch child.name {
            case "t":
                append(format.caps == true ? child.text.uppercased() : child.text)
            case "tab", "ptab": append("\t")
            case "br":
                let type = child.attribute("type")
                append(type == "page" && !state.inCell ? "\u{0C}" : "\u{2028}")
            case "cr": append("\u{2028}")
            case "noBreakHyphen": append("\u{2011}")
            case "softHyphen": append("\u{00AD}")
            case "sym":
                if let code = child.attribute("char").flatMap({ UInt32($0, radix: 16) }),
                    let scalar = UnicodeScalar(code)
                {
                    append(Self.bullet(String(Character(scalar))))
                }
            case "fldChar":
                switch child.attribute("fldCharType") {
                case "begin": state.fields.append(Field())
                case "separate":
                    guard !state.fields.isEmpty else { continue }
                    state.fields[state.fields.count - 1].separated = true
                    let instruction = state.fields[state.fields.count - 1].instruction
                    if let field = Self.pageField(instruction) {
                        state.fields[state.fields.count - 1].placeholder = true
                        if state.fields.dropLast().allSatisfy({ $0.separated && !$0.placeholder }) {
                            output.append(placeholder(field, format: format))
                        }
                    } else if let link = Self.fieldLink(instruction) {
                        state.links.append(link)
                        state.fields[state.fields.count - 1].instruction = "\u{1}LINK"
                    }
                case "end":
                    guard let field = state.fields.popLast() else { continue }
                    if field.instruction == "\u{1}LINK", !state.links.isEmpty {
                        state.links.removeLast()
                    }
                    if !field.separated, let page = Self.pageField(field.instruction),
                        showing()
                    {
                        output.append(placeholder(page, format: format))
                    }
                default: continue
                }
                if let link = state.links.last(where: { $0 != nil }) ?? nil {
                    attributes[.link] = link
                } else {
                    attributes[.link] = nil
                }
            case "instrText":
                if !state.fields.isEmpty, !state.fields[state.fields.count - 1].separated {
                    state.fields[state.fields.count - 1].instruction += child.text
                }
            case "drawing":
                drawing(
                    child, part: part, format: format, into: output, state: &state,
                    width: width, visible: visible && showing())
            case "pict", "object":
                vector(
                    child, part: part, format: format, into: output, state: &state,
                    width: width, visible: visible && showing())
            case "AlternateContent":
                let choice = child.child("Choice") ?? child.child("Fallback")
                content(
                    choice?.children ?? [], part: part, format: format, into: output,
                    state: &state, width: width)
            case "footnoteReference", "endnoteReference":
                let kind = child.name == "footnoteReference" ? "footnote" : "endnote"
                guard let id = child.attribute("id"), let note = noteTrees[kind]?[id],
                    visible
                else { continue }
                let number = notes.count + 1
                notes.append((number, note, notePart(kind)))
                output.append(superscript("\(number)", format: format, link: attributes[.link]))
            case "footnoteRef", "endnoteRef":
                if let currentNote {
                    output.append(superscript("\(currentNote)", format: format, link: nil))
                }
            default:
                continue
            }
        }
    }

    func notePart(_ kind: String) -> String {
        let relationships = Self.relationships(parts, for: main)
        let target = relationships.first { $0.type.hasSuffix("/" + kind + "s") }?.target
        return target.map { OOXMLRelationships.resolve($0, from: main) } ?? "word/\(kind)s.xml"
    }

    func superscript(_ text: String, format: DOCXRunFormat, link: Any?) -> NSAttributedString {
        var raised = format
        raised.vertical = "superscript"
        var attributes = attributes(raised)
        if let link { attributes[.link] = link }
        return NSAttributedString(string: text, attributes: attributes)
    }

    func drawing(
        _ node: XMLTree, part: String, format: DOCXRunFormat,
        into output: NSMutableAttributedString, state: inout Inline, width: CGFloat,
        visible: Bool
    ) {
        guard visible else { return }
        let frame = node.child("inline") ?? node.child("anchor")
        let extent = frame?.child("extent")
        let size = CGSize(
            width: CGFloat(extent?.number("cx") ?? 0) / 12700,
            height: CGFloat(extent?.number("cy") ?? 0) / 12700)
        if let blip = node.first("blip"),
            let id = blip.attribute("embed") ?? blip.attribute("link")
        {
            image(id, part: part, size: size, format: format, into: output, width: width)
        }
        for box in node.descendants("txbxContent") { state.boxes.append(box) }
    }

    func vector(
        _ node: XMLTree, part: String, format: DOCXRunFormat,
        into output: NSMutableAttributedString, state: inout Inline, width: CGFloat,
        visible: Bool
    ) {
        guard visible else { return }
        if let data = node.first("imagedata"), let id = data.attribute("id") {
            var size = CGSize.zero
            if let style = node.first("shape")?.attribute("style") {
                size = Self.vectorSize(style)
            }
            image(id, part: part, size: size, format: format, into: output, width: width)
        }
        for box in node.descendants("txbxContent") { state.boxes.append(box) }
    }

    static func vectorSize(_ style: String) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for declaration in style.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard pair.count == 2 else { continue }
            let number = CGFloat(Double(pair[1].filter { $0.isNumber || $0 == "." }) ?? 0)
            let value = pair[1].hasSuffix("in") ? number * 72 : number
            if pair[0] == "width" { width = value }
            if pair[0] == "height" { height = value }
        }
        return CGSize(width: width, height: height)
    }

    func image(
        _ id: String, part: String, size: CGSize, format: DOCXRunFormat,
        into output: NSMutableAttributedString, width: CGFloat
    ) {
        guard let path = targets(for: part)[id], let data = parts[path],
            let picture = NSImage(data: data)
        else { return }
        var bounds = size
        if bounds.width <= 0 || bounds.height <= 0 {
            bounds = picture.size
        }
        if bounds.width > width, width > 0 {
            bounds = CGSize(width: width, height: bounds.height * width / bounds.width)
        }
        let attachment = NSTextAttachment()
        attachment.image = picture
        attachment.bounds = CGRect(origin: .zero, size: bounds)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(attributes(format), range: NSRange(location: 0, length: text.length))
        output.append(text)
    }

    func table(
        _ node: XMLTree, part: String, into output: NSMutableAttributedString,
        cells parents: [NSTextBlock], width: CGFloat
    ) {
        struct Cell {
            let node: XMLTree
            let column: Int
            let span: Int
            let merge: String?
        }
        func flatten(_ nodes: [XMLTree], _ name: String) -> [XMLTree] {
            nodes.flatMap { node -> [XMLTree] in
                if node.name == name { return [node] }
                if node.name == "sdt" {
                    return flatten(node.child("sdtContent")?.children ?? [], name)
                }
                if node.name == "customXml" { return flatten(node.children, name) }
                return []
            }
        }
        let rows = flatten(node.children, "tr").map { row -> [Cell] in
            var column = Int(row.path("trPr", "gridBefore")?.number("val") ?? 0)
            return flatten(row.children, "tc").map { cell in
                let properties = cell.child("tcPr")
                let span = max(1, Int(properties?.child("gridSpan")?.number("val") ?? 1))
                let merge = properties?.child("vMerge").map { $0.attribute("val") ?? "continue" }
                defer { column += span }
                return Cell(node: cell, column: column, span: span, merge: merge)
            }
        }
        guard !rows.isEmpty else { return }
        var grid = (node.child("tblGrid")?.all("gridCol") ?? []).map {
            Self.points($0.number("w") ?? 0)
        }
        let columns = max(
            grid.count, rows.map { $0.map { $0.column + $0.span }.max() ?? 0 }.max() ?? 0)
        guard columns > 0 else { return }
        if grid.count < columns || grid.contains(where: { $0 <= 0 }) {
            grid = Array(repeating: width / CGFloat(columns), count: columns)
        }
        let total = grid.reduce(0, +)
        let scale = total > width && total > 0 ? width / total : 1
        grid = grid.map { $0 * scale }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setValue(grid.reduce(0, +), type: .absoluteValueType, for: .width)
        let borders = hasBorders(node)
        for (rowIndex, row) in rows.enumerated() {
            for cell in row where cell.merge != "continue" {
                var rowSpan = 1
                if cell.merge != nil {
                    for later in rows.dropFirst(rowIndex + 1) {
                        guard
                            later.contains(where: {
                                $0.column == cell.column && $0.merge == "continue"
                            })
                        else { break }
                        rowSpan += 1
                    }
                }
                let block = NSTextTableBlock(
                    table: table, startingRow: rowIndex, rowSpan: rowSpan,
                    startingColumn: cell.column, columnSpan: cell.span)
                let cellWidth = grid[
                    min(cell.column, columns - 1)..<min(cell.column + cell.span, columns)
                ].reduce(0, +)
                block.setValue(cellWidth, type: .absoluteValueType, for: .width)
                block.setWidth(5.4, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(5.4, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(1.5, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(1.5, type: .absoluteValueType, for: .padding, edge: .maxY)
                if borders {
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(.black)
                }
                let properties = cell.node.child("tcPr")
                if let fill = properties?.child("shd")?.attribute("fill"), fill != "auto",
                    let color = PresentationRenderer.hexColor(fill)
                {
                    block.backgroundColor = color
                }
                switch properties?.child("vAlign")?.attribute("val") {
                case "center": block.verticalAlignment = .middle
                case "bottom": block.verticalAlignment = .bottom
                default: block.verticalAlignment = .top
                }
                let before = output.length
                blocks(
                    cell.node.children, part: part, into: output, cells: parents + [block],
                    width: max(12, cellWidth - 10.8))
                if output.length == before {
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = parents + [block]
                    output.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: [
                                .paragraphStyle: style, DocumentMarkdown.headingKey: 0,
                            ]))
                }
            }
        }
    }

    func hasBorders(_ table: XMLTree) -> Bool {
        let properties = table.child("tblPr")
        let styleID = properties?.child("tblStyle")?.attribute("val")
        let sources =
            [properties?.child("tblBorders")]
            + styles.chain(styleID).reversed().map { $0.table?.child("tblBorders") }
        for borders in sources.compactMap({ $0 }) {
            return borders.children.contains { edge in
                let value = edge.attribute("val") ?? "nil"
                return value != "nil" && value != "none"
            }
        }
        let cellBorders = table.descendants("tcBorders").contains { borders in
            borders.children.contains { ($0.attribute("val") ?? "nil") != "nil" }
        }
        return cellBorders
    }

    static let families: Set<String> = Set(NSFontManager.shared.availableFontFamilies)
    static let substitutes = [
        "calibri": "Helvetica Neue", "calibri light": "Helvetica Neue", "aptos": "Helvetica Neue",
        "aptos display": "Helvetica Neue", "cambria": "Georgia", "segoe ui": "Helvetica Neue",
        "arial": "Arial", "times new roman": "Times New Roman",
        "liberation serif": "Times New Roman",
        "liberation sans": "Arial", "carlito": "Helvetica Neue", "caladea": "Georgia",
    ]

    static func family(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Times New Roman" }
        if families.contains(name) { return name }
        if let substitute = substitutes[name.lowercased()], families.contains(substitute) {
            return substitute
        }
        return "Helvetica Neue"
    }

    func attributes(_ format: DOCXRunFormat) -> [NSAttributedString.Key: Any] {
        var size = max(1, format.size ?? 10)
        var offset: CGFloat = 0
        if format.vertical == "superscript" {
            offset = size * 0.33
            size *= 0.65
        } else if format.vertical == "subscript" {
            offset = -size * 0.12
            size *= 0.65
        }
        var traits: NSFontTraitMask = []
        if format.bold == true { traits.insert(.boldFontMask) }
        if format.italic == true { traits.insert(.italicFontMask) }
        let family = Self.family(format.font)
        var font =
            NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size)
            ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont.systemFont(ofSize: size)
        if format.bold == true, !font.fontDescriptor.symbolicTraits.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if format.italic == true, !font.fontDescriptor.symbolicTraits.contains(.italic) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        var result: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: format.color ?? NSColor.black,
        ]
        if offset != 0 { result[.baselineOffset] = offset }
        if format.underline == true {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if format.strike == true {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let background = format.background { result[.backgroundColor] = background }
        return result
    }
}
