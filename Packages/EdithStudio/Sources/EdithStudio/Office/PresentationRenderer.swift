import AppKit
import CoreGraphics
import Foundation
import ImageIO

public enum PresentationRenderer {
    static let emu: CGFloat = 12700

    struct Part {
        let path: String
        let tree: XMLTree
        let relationships: [String: String]
    }

    struct Slide {
        let slide: Part
        let layout: Part?
        let master: Part?
    }

    struct Deck {
        let parts: [String: Data]
        let size: CGSize
        let slides: [Slide]
        let theme: [String: NSColor]
    }

    public struct SlideText: Equatable {
        public var title: String?
        public var lines: [String]
    }

    static func load(_ url: URL) throws -> Deck {
        let ext = url.pathExtension.lowercased()
        if ext == "key" {
            throw StudioError.unsupportedInput(
                url.lastPathComponent,
                "this tool. Export it from Keynote as PowerPoint or PDF first")
        }
        guard ext == "pptx" || ext == "pptm" || ext == "ppsx" else {
            throw StudioError.unsupportedInput(
                url.lastPathComponent, "this tool. Save it as PPTX first")
        }
        let parts: [String: Data]
        do {
            parts = try OOXMLPackage.read(url)
        } catch {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        guard let presentation = part("ppt/presentation.xml", in: parts) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        let sizeNode = presentation.tree.child("sldSz")
        let size = CGSize(
            width: (sizeNode?.number("cx") ?? 9_144_000) / emu,
            height: (sizeNode?.number("cy") ?? 6_858_000) / emu)
        var slides: [Slide] = []
        for identifier in presentation.tree.child("sldIdLst")?.all("sldId") ?? [] {
            guard let relationship = relationshipID(identifier),
                let target = presentation.relationships[relationship]
            else { continue }
            let slidePath = OOXMLRelationships.resolve(target, from: presentation.path)
            guard let slide = part(slidePath, in: parts) else { continue }
            let layout = relatedPart(of: slide, type: "slideLayout", in: parts)
            let master = layout.flatMap { relatedPart(of: $0, type: "slideMaster", in: parts) }
            slides.append(Slide(slide: slide, layout: layout, master: master))
        }
        let themePath = slides.first?.master.flatMap { master in
            master.relationships.values.first { $0.contains("theme") }.map {
                OOXMLRelationships.resolve($0, from: master.path)
            }
        }
        let theme = themeColors(themePath.flatMap { parts[$0] })
        return Deck(parts: parts, size: size, slides: slides, theme: theme)
    }

    static func relationshipID(_ node: XMLTree) -> String? {
        node.attributes["r:id"] ?? node.attributes.first { $0.key.hasSuffix(":id") }?.value
    }

    static func part(_ path: String, in parts: [String: Data]) -> Part? {
        guard let data = parts[path], let tree = XMLTree.parse(data) else { return nil }
        let relationships = parts[relsPath(path)].map(OOXMLRelationships.parse) ?? [:]
        return Part(path: path, tree: tree, relationships: relationships)
    }

    static func relatedPart(of part: Part, type: String, in parts: [String: Data]) -> Part? {
        guard let data = parts[relsPath(part.path)] else { return nil }
        let collector = ElementCollector(names: ["Relationship"])
        collector.run(data)
        guard
            let target = collector.elements.first(where: {
                $0["Type"]?.hasSuffix("/" + type) == true
            })?[
                "Target"]
        else { return nil }
        return self.part(OOXMLRelationships.resolve(target, from: part.path), in: parts)
    }

    static func relsPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        let folder = components.dropLast().joined(separator: "/")
        return (folder.isEmpty ? "" : folder + "/") + "_rels/" + (components.last ?? "") + ".rels"
    }

    static func themeColors(_ data: Data?) -> [String: NSColor] {
        var colors: [String: NSColor] = [
            "dk1": .black, "lt1": .white, "dk2": NSColor(white: 0.2, alpha: 1),
            "lt2": NSColor(white: 0.93, alpha: 1), "accent1": NSColor.systemBlue,
            "accent2": NSColor.systemOrange, "accent3": NSColor.systemGray,
            "accent4": NSColor.systemYellow, "accent5": NSColor.systemTeal,
            "accent6": NSColor.systemGreen, "hlink": NSColor.systemBlue,
            "folHlink": NSColor.systemPurple,
        ]
        guard let data, let tree = XMLTree.parse(data), let scheme = tree.first("clrScheme") else {
            return colors
        }
        for entry in scheme.children {
            if let hex = entry.child("srgbClr")?.attribute("val"), let color = hexColor(hex) {
                colors[entry.name] = color
            } else if let hex = entry.child("sysClr")?.attribute("lastClr"),
                let color = hexColor(hex)
            {
                colors[entry.name] = color
            }
        }
        return colors
    }

    static func hexColor(_ hex: String) -> NSColor? {
        guard let color = StudioColor(hex: hex) else { return nil }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    public static func render(
        _ url: URL, to output: URL, title: String, progress: (Double) -> Void = { _ in }
    ) throws -> Int {
        let deck = try load(url)
        guard !deck.slides.isEmpty else {
            throw StudioError.nothingToDo("The presentation has no slides.")
        }
        var box = CGRect(origin: .zero, size: deck.size)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title, kCGPDFContextCreator: "Edith Studio",
        ]
        guard let context = CGContext(output as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(output.lastPathComponent).")
        }
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        for (index, slide) in deck.slides.enumerated() {
            try Task.checkCancellation()
            context.beginPage(mediaBox: &box)
            context.saveGState()
            context.translateBy(x: 0, y: deck.size.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            appearance.performAsCurrentDrawingAppearance {
                SlideDrawer(deck: deck, slide: slide).draw(in: box)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPage()
            progress(Double(index + 1) / Double(deck.slides.count))
        }
        context.closePDF()
        return deck.slides.count
    }

    public static func text(_ url: URL) throws -> [SlideText] {
        let deck = try load(url)
        return deck.slides.map { slide in
            var result = SlideText(title: nil, lines: [])
            for shape in slide.slide.tree.descendants("sp") {
                let type = shape.path("nvSpPr", "nvPr", "ph")?.attribute("type")
                let paragraphs = (shape.child("txBody")?.all("p") ?? []).map(paragraphText).filter {
                    !$0.isEmpty
                }
                if (type == "title" || type == "ctrTitle"), result.title == nil {
                    result.title = paragraphs.joined(separator: " ")
                } else {
                    result.lines += paragraphs
                }
            }
            for table in slide.slide.tree.descendants("tbl") {
                for row in table.all("tr") {
                    let cells = row.all("tc").map { cell in
                        (cell.child("txBody")?.all("p") ?? []).map(paragraphText).joined(
                            separator: " ")
                    }
                    result.lines.append(cells.joined(separator: " | "))
                }
            }
            return result
        }
    }

    static func paragraphText(_ paragraph: XMLTree) -> String {
        var text = ""
        for child in paragraph.children {
            switch child.name {
            case "r", "fld": text += child.child("t")?.text ?? ""
            case "br": text += "\n"
            default: break
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

struct SlideDrawer {
    let deck: PresentationRenderer.Deck
    let slide: PresentationRenderer.Slide

    typealias Mapper = (CGRect) -> CGRect

    func draw(in box: CGRect) {
        background().setFill()
        box.fill()
        let slideRoot = slide.slide.tree
        let showMaster = slideRoot.attribute("showMasterSp") != "0"
        let layoutShowsMaster = slide.layout?.tree.attribute("showMasterSp") != "0"
        if showMaster {
            if layoutShowsMaster, let master = slide.master {
                drawTree(master, placeholders: false, mapper: { $0 })
            }
            if let layout = slide.layout { drawTree(layout, placeholders: false, mapper: { $0 }) }
        }
        drawTree(slide.slide, placeholders: true, mapper: { $0 })
    }

    func background() -> NSColor {
        for part in [slide.slide, slide.layout, slide.master].compactMap({ $0 }) {
            guard let background = part.tree.path("cSld", "bg") else { continue }
            if let properties = background.child("bgPr"), let color = fillColor(properties) {
                return color
            }
            if let reference = background.child("bgRef"), let color = color(from: reference) {
                return color
            }
        }
        return .white
    }

    func drawTree(_ part: PresentationRenderer.Part, placeholders: Bool, mapper: @escaping Mapper) {
        guard let tree = part.tree.path("cSld", "spTree") else { return }
        drawChildren(of: tree, part: part, placeholders: placeholders, mapper: mapper)
    }

    func drawChildren(
        of node: XMLTree, part: PresentationRenderer.Part, placeholders: Bool,
        mapper: @escaping Mapper
    ) {
        for child in node.children {
            switch child.name {
            case "sp", "cxnSp":
                let placeholder = child.path("nvSpPr", "nvPr", "ph")
                if placeholder != nil && !placeholders { continue }
                drawShape(child, placeholder: placeholder, part: part, mapper: mapper)
            case "pic":
                if child.path("nvPicPr", "nvPr", "ph") != nil && !placeholders { continue }
                drawPicture(child, part: part, mapper: mapper)
            case "grpSp":
                drawGroup(child, part: part, placeholders: placeholders, mapper: mapper)
            case "graphicFrame":
                drawFrame(child, mapper: mapper)
            default:
                continue
            }
        }
    }

    func rect(_ xfrm: XMLTree?) -> CGRect? {
        guard let xfrm, let offset = xfrm.child("off"), let extent = xfrm.child("ext") else {
            return nil
        }
        let scale = PresentationRenderer.emu
        return CGRect(
            x: (offset.number("x") ?? 0) / scale, y: (offset.number("y") ?? 0) / scale,
            width: (extent.number("cx") ?? 0) / scale, height: (extent.number("cy") ?? 0) / scale)
    }

    func drawGroup(
        _ group: XMLTree, part: PresentationRenderer.Part, placeholders: Bool,
        mapper: @escaping Mapper
    ) {
        let xfrm = group.path("grpSpPr", "xfrm")
        guard let frame = rect(xfrm), let childOffset = xfrm?.child("chOff"),
            let childExtent = xfrm?.child("chExt")
        else {
            drawChildren(of: group, part: part, placeholders: placeholders, mapper: mapper)
            return
        }
        let scale = PresentationRenderer.emu
        let child = CGRect(
            x: (childOffset.number("x") ?? 0) / scale, y: (childOffset.number("y") ?? 0) / scale,
            width: max(1, (childExtent.number("cx") ?? 1) / scale),
            height: max(1, (childExtent.number("cy") ?? 1) / scale))
        let mapped = mapper(frame)
        let inner: Mapper = { rect in
            CGRect(
                x: mapped.minX + (rect.minX - child.minX) * mapped.width / child.width,
                y: mapped.minY + (rect.minY - child.minY) * mapped.height / child.height,
                width: rect.width * mapped.width / child.width,
                height: rect.height * mapped.height / child.height)
        }
        drawChildren(of: group, part: part, placeholders: placeholders, mapper: inner)
    }

    struct PlaceholderKey {
        let type: String
        let index: String?
    }

    func key(_ placeholder: XMLTree?) -> PlaceholderKey? {
        guard let placeholder else { return nil }
        return PlaceholderKey(
            type: placeholder.attribute("type") ?? "body", index: placeholder.attribute("idx"))
    }

    func inherited(_ key: PlaceholderKey) -> [XMLTree] {
        var result: [XMLTree] = []
        for part in [slide.layout, slide.master].compactMap({ $0 }) {
            let shapes = part.tree.descendants("sp")
            let match =
                shapes.first { shape in
                    guard let index = key.index,
                        let other = shape.path("nvSpPr", "nvPr", "ph")?.attribute("idx")
                    else { return false }
                    return index == other
                }
                ?? shapes.first { shape in
                    guard let placeholder = shape.path("nvSpPr", "nvPr", "ph") else { return false }
                    return normalizedType(placeholder.attribute("type") ?? "body")
                        == normalizedType(key.type)
                }
            if let match { result.append(match) }
        }
        return result
    }

    func normalizedType(_ type: String) -> String {
        switch type {
        case "ctrTitle", "title": "title"
        case "subTitle", "obj", "body": "body"
        default: type
        }
    }

    func drawShape(
        _ shape: XMLTree, placeholder: XMLTree?, part: PresentationRenderer.Part,
        mapper: Mapper
    ) {
        let key = key(placeholder)
        let chain = key.map(inherited) ?? []
        guard
            let base = rect(shape.path("spPr", "xfrm"))
                ?? chain.lazy.compactMap({ self.rect($0.path("spPr", "xfrm")) }).first
        else { return }
        let frame = mapper(base)
        guard frame.width > 0 || frame.height > 0 else { return }
        if let properties = shape.child("spPr") { drawGeometry(properties, frame: frame) }
        guard let body = shape.child("txBody") else { return }
        drawText(body, frame: frame, placeholder: key, chain: chain)
    }

    func drawGeometry(_ properties: XMLTree, frame: CGRect) {
        let preset = properties.child("prstGeom")?.attribute("prst") ?? "rect"
        let path: NSBezierPath
        switch preset {
        case "ellipse":
            path = NSBezierPath(ovalIn: frame)
        case "roundRect":
            let radius = min(frame.width, frame.height) * 0.16
            path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        case "line", "straightConnector1":
            path = NSBezierPath()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
        default:
            path = NSBezierPath(rect: frame)
        }
        if let fill = fillColor(properties) {
            fill.setFill()
            path.fill()
        }
        if let line = properties.child("ln"), line.child("noFill") == nil,
            let color = fillColor(line)
        {
            color.setStroke()
            path.lineWidth = max(0.5, (line.number("w") ?? 12700) / PresentationRenderer.emu)
            path.stroke()
        }
    }

    func fillColor(_ node: XMLTree) -> NSColor? {
        if node.child("noFill") != nil { return nil }
        if let solid = node.child("solidFill") { return color(from: solid) }
        if let gradient = node.child("gradFill"),
            let stop = gradient.child("gsLst")?.all("gs").first
        {
            return color(from: stop)
        }
        return nil
    }

    func color(from node: XMLTree) -> NSColor? {
        for child in node.children {
            var base: NSColor?
            switch child.name {
            case "srgbClr": base = child.attribute("val").flatMap(PresentationRenderer.hexColor)
            case "sysClr":
                base = (child.attribute("lastClr") ?? child.attribute("val")).flatMap(
                    PresentationRenderer.hexColor)
            case "schemeClr": base = scheme(child.attribute("val") ?? "tx1")
            case "prstClr":
                base = child.attribute("val") == "white" ? .white : .black
            default: continue
            }
            guard var color = base?.usingColorSpace(.sRGB) else { continue }
            color = modified(color, by: child)
            return color
        }
        return nil
    }

    func scheme(_ name: String) -> NSColor? {
        let mapped: String
        switch name {
        case "tx1": mapped = "dk1"
        case "bg1": mapped = "lt1"
        case "tx2": mapped = "dk2"
        case "bg2": mapped = "lt2"
        default: mapped = name
        }
        return deck.theme[mapped]
    }

    func modified(_ color: NSColor, by node: XMLTree) -> NSColor {
        var red = color.redComponent
        var green = color.greenComponent
        var blue = color.blueComponent
        var alpha: CGFloat = 1
        for modifier in node.children {
            let value = CGFloat((modifier.number("val") ?? 100_000) / 100_000)
            switch modifier.name {
            case "lumMod":
                red *= value
                green *= value
                blue *= value
            case "lumOff":
                red += value
                green += value
                blue += value
            case "tint":
                red += (1 - red) * (1 - value)
                green += (1 - green) * (1 - value)
                blue += (1 - blue) * (1 - value)
            case "shade":
                red *= value
                green *= value
                blue *= value
            case "alpha":
                alpha = value
            default: continue
            }
        }
        return NSColor(
            srgbRed: min(max(red, 0), 1), green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1), alpha: alpha)
    }

    func textStyle(for key: PlaceholderKey?) -> XMLTree? {
        let styles = slide.master?.tree.child("txStyles")
        guard let key else { return styles?.child("otherStyle") }
        switch normalizedType(key.type) {
        case "title": return styles?.child("titleStyle")
        case "body": return styles?.child("bodyStyle")
        default: return styles?.child("otherStyle")
        }
    }

    func levelProperties(level: Int, chain: [XMLTree], key: PlaceholderKey?) -> [XMLTree] {
        let name = "lvl\(level + 1)pPr"
        var result: [XMLTree] = []
        for shape in chain {
            if let properties = shape.path("txBody", "lstStyle", name) { result.append(properties) }
        }
        if let style = textStyle(for: key)?.child(name) { result.append(style) }
        return result
    }

    func drawText(_ body: XMLTree, frame: CGRect, placeholder: PlaceholderKey?, chain: [XMLTree]) {
        let bodyProperties = body.child("bodyPr")
        let inheritedBody = chain.compactMap { $0.path("txBody", "bodyPr") }
        func inset(_ name: String, _ fallback: Double) -> CGFloat {
            let value =
                bodyProperties?.number(name) ?? inheritedBody.lazy.compactMap { $0.number(name) }
                .first
                ?? fallback
            return value / PresentationRenderer.emu
        }
        let insets = NSEdgeInsets(
            top: inset("tIns", 45720), left: inset("lIns", 91440), bottom: inset("bIns", 45720),
            right: inset("rIns", 91440))
        let area = CGRect(
            x: frame.minX + insets.left, y: frame.minY + insets.top,
            width: max(4, frame.width - insets.left - insets.right),
            height: max(4, frame.height - insets.top - insets.bottom))
        let anchor =
            bodyProperties?.attribute("anchor")
            ?? inheritedBody.lazy.compactMap { $0.attribute("anchor") }.first
            ?? (placeholder.map { normalizedType($0.type) == "title" } == true ? "ctr" : "t")
        var scale: CGFloat = 1
        if let fontScale = bodyProperties?.child("normAutofit")?.number("fontScale") {
            scale = fontScale / 100_000
        }
        var text = attributed(body, placeholder: placeholder, chain: chain, scale: scale)
        guard text.length > 0 else { return }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        var size = text.boundingRect(
            with: CGSize(width: area.width, height: 10_000), options: options
        ).size
        var attempts = 0
        while size.height > area.height * 1.02, attempts < 8 {
            scale *= 0.88
            text = attributed(body, placeholder: placeholder, chain: chain, scale: scale)
            size =
                text.boundingRect(with: CGSize(width: area.width, height: 10_000), options: options)
                .size
            attempts += 1
        }
        var origin = area.minY
        switch anchor {
        case "ctr": origin = area.midY - size.height / 2
        case "b": origin = area.maxY - size.height
        default: break
        }
        text.draw(
            with: CGRect(
                x: area.minX, y: origin, width: area.width, height: max(size.height, area.height)),
            options: options)
    }

    func attributed(
        _ body: XMLTree, placeholder: PlaceholderKey?, chain: [XMLTree], scale: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let isBody = placeholder.map { $0.type == "body" || $0.type == "obj" } ?? false
        for (index, paragraph) in body.all("p").enumerated() {
            let properties = paragraph.child("pPr")
            let level = Int(properties?.attribute("lvl") ?? "0") ?? 0
            let inheritedLevels = levelProperties(level: level, chain: chain, key: placeholder)
            let defaults = inheritedLevels.compactMap { $0.child("defRPr") }
            let style = NSMutableParagraphStyle()
            let alignment =
                properties?.attribute("algn")
                ?? inheritedLevels.lazy.compactMap { $0.attribute("algn") }.first ?? "l"
            switch alignment {
            case "ctr": style.alignment = .center
            case "r": style.alignment = .right
            case "just": style.alignment = .justified
            default: style.alignment = .left
            }
            style.paragraphSpacing = 4 * scale
            let text = PresentationRenderer.paragraphText(paragraph)
            var bullet: String?
            let noBullet =
                properties?.child("buNone") != nil
                || inheritedLevels.contains { $0.child("buNone") != nil }
            if !noBullet, !text.isEmpty {
                if let character =
                    properties?.child("buChar")?.attribute("char")
                    ?? inheritedLevels.lazy.compactMap({ $0.child("buChar")?.attribute("char") })
                    .first,
                    isBody || properties?.child("buChar") != nil
                {
                    bullet = character
                } else if properties?.child("buAutoNum") != nil {
                    bullet = "\(index + 1)."
                }
            }
            if bullet != nil {
                let indent = CGFloat(level) * 24 * scale + 18 * scale
                style.headIndent = indent
                style.firstLineHeadIndent = indent - 18 * scale
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let paragraphStart = result.length
            var firstRun = paragraph.children.first { $0.name == "r" }?.child("rPr")
            if firstRun == nil { firstRun = properties?.child("defRPr") }
            if let bullet {
                result.append(
                    NSAttributedString(
                        string: bullet + "\t",
                        attributes: runAttributes(firstRun, defaults: defaults, scale: scale)))
            }
            for child in paragraph.children {
                switch child.name {
                case "r", "fld":
                    let content = child.child("t")?.text ?? ""
                    result.append(
                        NSAttributedString(
                            string: content,
                            attributes: runAttributes(
                                child.child("rPr"), defaults: defaults, scale: scale)))
                case "br":
                    result.append(
                        NSAttributedString(
                            string: "\u{2028}",
                            attributes: runAttributes(
                                child.child("rPr"), defaults: defaults, scale: scale)))
                default: continue
                }
            }
            if result.length == paragraphStart {
                result.append(
                    NSAttributedString(
                        string: " ",
                        attributes: runAttributes(
                            paragraph.child("endParaRPr"), defaults: defaults, scale: scale)))
            }
            result.addAttribute(
                .paragraphStyle, value: style,
                range: NSRange(location: paragraphStart, length: result.length - paragraphStart))
        }
        return result
    }

    func runAttributes(_ properties: XMLTree?, defaults: [XMLTree], scale: CGFloat)
        -> [NSAttributedString.Key: Any]
    {
        let sources = [properties].compactMap { $0 } + defaults
        let size = (sources.lazy.compactMap { $0.number("sz") }.first ?? 1800) / 100 * scale
        let bold =
            sources.lazy.compactMap { $0.attribute("b") }.first.map { $0 == "1" || $0 == "true" }
            ?? false
        let italic =
            sources.lazy.compactMap { $0.attribute("i") }.first.map { $0 == "1" || $0 == "true" }
            ?? false
        let typeface = sources.lazy.compactMap { $0.child("latin")?.attribute("typeface") }.first
        var font =
            typeface.flatMap { $0.hasPrefix("+") ? nil : NSFont(name: $0, size: max(size, 4)) }
            ?? NSFont.systemFont(ofSize: max(size, 4))
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let color =
            sources.lazy.compactMap { source in source.child("solidFill").flatMap(self.color(from:))
            }
            .first ?? scheme("tx1") ?? .black
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if sources.lazy.compactMap({ $0.attribute("u") }).first.map({ $0 != "none" }) == true {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    func drawPicture(_ picture: XMLTree, part: PresentationRenderer.Part, mapper: Mapper) {
        guard let base = rect(picture.path("spPr", "xfrm")),
            let blip = picture.path("blipFill", "blip"),
            let identifier = blip.attributes["r:embed"] ?? blip.attribute("embed"),
            let target = part.relationships[identifier]
        else { return }
        let path = OOXMLRelationships.resolve(target, from: part.path)
        guard let data = deck.parts[path],
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        if let crop = picture.path("blipFill", "srcRect") {
            let left = (crop.number("l") ?? 0) / 100_000
            let top = (crop.number("t") ?? 0) / 100_000
            let right = (crop.number("r") ?? 0) / 100_000
            let bottom = (crop.number("b") ?? 0) / 100_000
            let region = CGRect(
                x: left * Double(image.width), y: top * Double(image.height),
                width: max(1, (1 - left - right) * Double(image.width)),
                height: max(1, (1 - top - bottom) * Double(image.height)))
            if let cropped = image.cropping(to: region.integral) { image = cropped }
        }
        let frame = mapper(base)
        let nsImage = NSImage(
            cgImage: image, size: CGSize(width: image.width, height: image.height))
        nsImage.draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    func drawFrame(_ frame: XMLTree, mapper: Mapper) {
        guard let base = rect(frame.child("xfrm")),
            let table = frame.first("tbl")
        else { return }
        let area = mapper(base)
        let scale = PresentationRenderer.emu
        let columns = (table.child("tblGrid")?.all("gridCol") ?? []).map {
            ($0.number("w") ?? 0) / scale
        }
        let totalWidth = max(1, columns.reduce(0, +))
        let widths = columns.map { $0 * area.width / totalWidth }
        let rows = table.all("tr")
        let heights = rows.map { ($0.number("h") ?? 370_840) / scale }
        let totalHeight = max(1, heights.reduce(0, +))
        let rowScale = max(1, area.height / totalHeight)
        var y = area.minY
        for (rowIndex, row) in rows.enumerated() {
            let height = heights[rowIndex] * rowScale
            var x = area.minX
            for (column, cell) in row.all("tc").enumerated() where column < widths.count {
                let rect = CGRect(x: x, y: y, width: widths[column], height: height)
                if let properties = cell.child("tcPr"), let fill = fillColor(properties) {
                    fill.setFill()
                    rect.fill()
                } else if rowIndex == 0 {
                    (deck.theme["accent1"] ?? .systemBlue).setFill()
                    rect.fill()
                }
                NSColor(white: 0.7, alpha: 1).setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 0.5
                border.stroke()
                if let body = cell.child("txBody") {
                    let text = attributed(body, placeholder: nil, chain: [], scale: 0.8)
                    let colored = NSMutableAttributedString(attributedString: text)
                    if rowIndex == 0, cell.child("tcPr").flatMap(fillColor) == nil {
                        colored.addAttribute(
                            .foregroundColor, value: NSColor.white,
                            range: NSRange(location: 0, length: colored.length))
                    }
                    colored.draw(
                        with: rect.insetBy(dx: 5, dy: 3),
                        options: [
                            .usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine,
                        ])
                }
                x += widths[column]
            }
            y += height
        }
    }
}
