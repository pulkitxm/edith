import Foundation

public struct SpreadsheetSheet: Equatable, Sendable {
    public var name: String
    public var rows: [[String]]

    public init(name: String, rows: [[String]]) {
        self.name = name
        self.rows = rows
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

public enum SpreadsheetReader {
    public static func read(_ url: URL) throws -> [SpreadsheetSheet] {
        switch url.pathExtension.lowercased() {
        case "csv":
            let text = try DocumentLoader.readText(url)
            return [
                SpreadsheetSheet(name: url.studioStem, rows: CSVParser.parse(text, delimiter: nil))
            ]
        case "tsv":
            let text = try DocumentLoader.readText(url)
            return [
                SpreadsheetSheet(name: url.studioStem, rows: CSVParser.parse(text, delimiter: "\t"))
            ]
        case "xlsx", "xlsm":
            return try XLSXReader.read(url)
        case "numbers":
            throw StudioError.unsupportedInput(
                url.lastPathComponent, "this tool. Export it from Numbers as Excel or CSV first")
        default:
            throw StudioError.unsupportedInput(
                url.lastPathComponent, "this tool. Save it as XLSX or CSV first")
        }
    }
}

public enum CSVParser {
    public static func parse(_ text: String, delimiter: Character?) -> [[String]] {
        let separator = delimiter ?? detect(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let value = pending {
                pending = nil
                return value
            }
            return iterator.next()
        }
        while let character = next() {
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" {
                            field.append("\"")
                        } else {
                            quoted = false
                            pending = following
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case separator:
                row.append(field)
                field = ""
            case "\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func detect(_ text: String) -> Character {
        let sample = text.prefix(4000)
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in
            sample.filter { $0 == a }.count < sample.filter { $0 == b }.count
        } ?? ","
    }
}

enum XLSXReader {
    static func read(_ url: URL) throws -> [SpreadsheetSheet] {
        try OOXMLPackage.requirePackage(url, application: "Excel", format: "XLSX")
        let parts: [String: Data]
        do {
            parts = try OOXMLPackage.read(url)
        } catch {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        let workbookPath = DOCXReader.mainPart(parts) ?? "xl/workbook.xml"
        guard let workbook = parts[workbookPath] ?? parts["xl/workbook.xml"] else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        let relationships =
            parts[PresentationRenderer.relsPath(workbookPath)].map(OOXMLRelationships.parse) ?? [:]
        func related(_ type: String, fallback: String) -> Data? {
            guard let data = parts[PresentationRenderer.relsPath(workbookPath)] else {
                return parts[fallback]
            }
            let collector = ElementCollector(names: ["Relationship"])
            collector.run(data)
            let target = collector.elements.first { $0["Type"]?.hasSuffix("/" + type) == true }?[
                "Target"]
            return target.flatMap { parts[OOXMLRelationships.resolve($0, from: workbookPath)] }
                ?? parts[fallback]
        }
        let shared =
            related("sharedStrings", fallback: "xl/sharedStrings.xml").map(
                SharedStringsParser.parse)
            ?? []
        let formats =
            related("styles", fallback: "xl/styles.xml").map(StylesParser.formats) ?? []
        let book = WorkbookParser.parse(workbook)
        var sheets: [SpreadsheetSheet] = []
        for entry in book.sheets where entry.visible {
            guard let target = relationships[entry.relationship] else { continue }
            let path = OOXMLRelationships.resolve(target, from: workbookPath)
            guard let data = parts[path] else { continue }
            let rows = WorksheetParser.parse(
                data, shared: shared, formats: formats, date1904: book.date1904)
            sheets.append(SpreadsheetSheet(name: entry.name, rows: rows))
        }
        return sheets
    }

    static func unescape(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let pattern = try? NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_")
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern?.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            ?? []
        {
            result += nsText.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            let code = UInt32(nsText.substring(with: match.range(at: 1)), radix: 16) ?? 0x3F
            result += code == 0x0D ? "" : String(Character(UnicodeScalar(code) ?? "?"))
            cursor = match.range.location + match.range.length
        }
        return result + nsText.substring(from: cursor)
    }
}

public enum OOXMLRelationships {
    public static func parse(_ data: Data) -> [String: String] {
        let delegate = ElementCollector(names: ["Relationship"])
        delegate.run(data)
        var result: [String: String] = [:]
        for element in delegate.elements {
            if let id = element["Id"], let target = element["Target"] { result[id] = target }
        }
        return result
    }

    public static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = part.split(separator: "/").map(String.init)
        if !components.isEmpty { components.removeLast() }
        for piece in target.split(separator: "/").map(String.init) {
            if piece == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if piece != "." {
                components.append(piece)
            }
        }
        return components.joined(separator: "/")
    }
}

final class ElementCollector: NSObject, XMLParserDelegate {
    let names: Set<String>
    var elements: [[String: String]] = []

    init(names: Set<String>) {
        self.names = names
    }

    func run(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        if names.contains(Self.local(elementName)) { elements.append(attributes) }
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

enum WorkbookParser {
    struct Entry {
        let name: String
        let relationship: String
        let visible: Bool
    }

    static func parse(_ data: Data) -> (sheets: [Entry], date1904: Bool) {
        let collector = ElementCollector(names: ["sheet", "workbookPr"])
        collector.run(data)
        var date1904 = false
        var sheets: [Entry] = []
        for attributes in collector.elements {
            if let value = attributes["date1904"] {
                date1904 = value == "1" || value.lowercased() == "true"
                continue
            }
            guard let name = attributes["name"],
                let id = attributes["r:id"]
                    ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value
            else { continue }
            let state = attributes["state"] ?? "visible"
            sheets.append(Entry(name: name, relationship: id, visible: state == "visible"))
        }
        return (sheets, date1904)
    }
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    var current = ""
    var inItem = false
    var inText = false
    var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch ElementCollector.local(elementName) {
        case "si":
            inItem = true
            current = ""
        case "t": inText = inItem && !inPhonetic
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch ElementCollector.local(elementName) {
        case "si":
            strings.append(XLSXReader.unescape(current))
            inItem = false
        case "t": inText = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

final class StylesParser: NSObject, XMLParserDelegate {
    var custom: [Int: String] = [:]
    var cellFormats: [Int] = []
    var inCellXfs = false

    static func formats(_ data: Data) -> [String] {
        let delegate = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.cellFormats.map { SpreadsheetFormat.code(for: $0, custom: delegate.custom) }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch ElementCollector.local(elementName) {
        case "numFmt":
            guard let id = attributes["numFmtId"].flatMap(Int.init),
                let code = attributes["formatCode"]
            else { return }
            custom[id] = code
        case "cellXfs": inCellXfs = true
        case "xf" where inCellXfs:
            cellFormats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
        default: break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        if ElementCollector.local(elementName) == "cellXfs" { inCellXfs = false }
    }
}

final class WorksheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    let formats: [String]
    let date1904: Bool
    var rows: [Int: [Int: String]] = [:]
    var hiddenRows = Set<Int>()
    var hiddenColumns = Set<Int>()
    var rowIndex = 0
    var column = 0
    var cellType = ""
    var cellStyle = 0
    var value = ""
    var inline = ""
    var capturing: String?
    var inInline = false
    var inPhonetic = false

    init(shared: [String], formats: [String], date1904: Bool) {
        self.shared = shared
        self.formats = formats
        self.date1904 = date1904
    }

    static func parse(
        _ data: Data, shared: [String], formats: [String] = [], date1904: Bool = false
    ) -> [[String]] {
        let delegate = WorksheetParser(shared: shared, formats: formats, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let visibleRows = delegate.rows.keys.filter { !delegate.hiddenRows.contains($0) }
        guard let last = visibleRows.max() else { return [] }
        let columns = (delegate.rows.values.compactMap { $0.keys.max() }.max() ?? -1) + 1
        let keptColumns = (0..<max(columns, 0)).filter { !delegate.hiddenColumns.contains($0) }
        return (0...last).compactMap { index in
            guard !delegate.hiddenRows.contains(index) else { return nil }
            guard let cells = delegate.rows[index] else { return [] }
            let values = keptColumns.map { cells[$0] ?? "" }
            guard let width = values.lastIndex(where: { !$0.isEmpty }) else { return [] }
            return Array(values[...width])
        }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch ElementCollector.local(elementName) {
        case "row":
            if let number = attributes["r"].flatMap(Int.init) {
                rowIndex = number - 1
            } else {
                rowIndex = (rows.keys.max() ?? -1) + 1
            }
            if let hidden = attributes["hidden"], hidden == "1" || hidden == "true" {
                hiddenRows.insert(rowIndex)
            }
            column = 0
        case "col":
            if let hidden = attributes["hidden"], hidden == "1" || hidden == "true",
                let minimum = attributes["min"].flatMap(Int.init),
                let maximum = attributes["max"].flatMap(Int.init), minimum <= maximum,
                maximum - minimum < 16_384
            {
                for index in minimum...maximum { hiddenColumns.insert(index - 1) }
            }
        case "c":
            if let reference = attributes["r"] {
                column = Self.columnIndex(reference)
            }
            cellType = attributes["t"] ?? "n"
            cellStyle = attributes["s"].flatMap(Int.init) ?? 0
            value = ""
            inline = ""
        case "v":
            capturing = "v"
        case "is":
            inInline = true
        case "rPh":
            inPhonetic = true
        case "t" where inInline && !inPhonetic:
            capturing = "t"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch capturing {
        case "v": value += string
        case "t": inline += string
        default: break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        switch ElementCollector.local(elementName) {
        case "v", "t": capturing = nil
        case "is": inInline = false
        case "rPh": inPhonetic = false
        case "c":
            let text = display()
            if !text.isEmpty { rows[rowIndex, default: [:]][column] = text }
            column += 1
        default: break
        }
    }

    var format: String {
        cellStyle >= 0 && cellStyle < formats.count ? formats[cellStyle] : "General"
    }

    func display() -> String {
        switch cellType {
        case "s":
            guard let index = Int(value.trimmingCharacters(in: .whitespaces)), index >= 0,
                index < shared.count
            else { return "" }
            return shared[index]
        case "inlineStr": return XLSXReader.unescape(inline)
        case "b": return value.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
        case "str", "e": return XLSXReader.unescape(value)
        case "d":
            guard let serial = Self.serial(isoDate: value, date1904: date1904) else { return value }
            let code = format.lowercased() == "general" ? Self.isoCode(value) : format
            return SpreadsheetFormat.display(serial, code: code, date1904: date1904)
        default:
            guard let number = Double(value.trimmingCharacters(in: .whitespaces)) else {
                return value
            }
            return SpreadsheetFormat.display(number, code: format, date1904: date1904)
        }
    }

    static func isoCode(_ value: String) -> String {
        value.contains("T") && !value.hasSuffix("T00:00:00") && !value.hasSuffix("T00:00:00Z")
            ? "yyyy-mm-dd hh:mm:ss" : "yyyy-mm-dd"
    }

    static func serial(isoDate: String, date1904: Bool) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        var date = formatter.date(from: isoDate)
        if date == nil {
            formatter.formatOptions = [.withFullDate]
            date = formatter.date(from: String(isoDate.prefix(10)))
        }
        if date == nil {
            formatter.formatOptions = [
                .withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate,
            ]
            date = formatter.date(from: isoDate)
        }
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let origin = calendar.date(
            from: date1904
                ? DateComponents(year: 1904, month: 1, day: 1)
                : DateComponents(year: 1899, month: 12, day: 30))!
        let serial = date.timeIntervalSince(origin) / 86_400
        return !date1904 && serial < 61 ? serial - 1 : serial
    }

    static func format(_ number: Double) -> String {
        SpreadsheetFormat.general(number)
    }

    static func date(fromSerial serial: Double) -> String {
        SpreadsheetFormat.display(serial, code: "yyyy-mm-dd")
    }

    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard
                scalar.value >= 65 && scalar.value <= 90
                    || scalar.value >= 97 && scalar.value <= 122
            else { break }
            let value = Int(scalar.value >= 97 ? scalar.value - 32 : scalar.value) - 64
            index = index * 26 + value
        }
        return max(0, index - 1)
    }
}
