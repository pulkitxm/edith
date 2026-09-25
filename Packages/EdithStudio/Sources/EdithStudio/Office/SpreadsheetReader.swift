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
        let parts: [String: Data]
        do {
            parts = try OOXMLPackage.read(url)
        } catch {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        guard let workbook = parts["xl/workbook.xml"] else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        let relationships = parts["xl/_rels/workbook.xml.rels"].map(OOXMLRelationships.parse) ?? [:]
        let shared = parts["xl/sharedStrings.xml"].map(SharedStringsParser.parse) ?? []
        let dateStyles = parts["xl/styles.xml"].map(StylesParser.dateStyles) ?? []
        var sheets: [SpreadsheetSheet] = []
        for entry in WorkbookParser.parse(workbook) {
            guard let target = relationships[entry.relationship] else { continue }
            let path = OOXMLRelationships.resolve(target, from: "xl/workbook.xml")
            guard let data = parts[path] else { continue }
            let rows = WorksheetParser.parse(data, shared: shared, dateStyles: dateStyles)
            sheets.append(SpreadsheetSheet(name: entry.name, rows: rows))
        }
        return sheets
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
        components.removeLast()
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
    }

    static func parse(_ data: Data) -> [Entry] {
        let collector = ElementCollector(names: ["sheet"])
        collector.run(data)
        return collector.elements.compactMap { attributes in
            guard let name = attributes["name"], let id = attributes["r:id"] ?? attributes["id"]
            else { return nil }
            return Entry(name: name, relationship: id)
        }
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
            strings.append(current)
            inItem = false
        case "t": inText = false
        case "rPh": inPhonetic = false
        default: break
        }
    }
}

final class StylesParser: NSObject, XMLParserDelegate {
    var customDateFormats = Set<Int>()
    var cellFormats: [Int] = []
    var inCellXfs = false

    static let builtInDates: Set<Int> = Set(14...22).union(45...47)

    static func dateStyles(_ data: Data) -> Set<Int> {
        let delegate = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        var result = Set<Int>()
        for (index, format) in delegate.cellFormats.enumerated()
        where builtInDates.contains(format) || delegate.customDateFormats.contains(format) {
            result.insert(index)
        }
        return result
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        switch ElementCollector.local(elementName) {
        case "numFmt":
            guard let id = attributes["numFmtId"].flatMap(Int.init),
                let code = attributes["formatCode"]?.lowercased()
            else { return }
            let stripped = code.replacingOccurrences(
                of: #"\[[^\]]*\]|"[^"]*""#, with: "", options: .regularExpression)
            if stripped.contains("y") || stripped.contains("d")
                || (stripped.contains("m") && !stripped.contains("0"))
            {
                customDateFormats.insert(id)
            }
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
    let dateStyles: Set<Int>
    var rows: [Int: [Int: String]] = [:]
    var rowIndex = 0
    var column = 0
    var cellType = ""
    var cellStyle = 0
    var value = ""
    var inline = ""
    var capturing: String?
    var inInline = false

    init(shared: [String], dateStyles: Set<Int>) {
        self.shared = shared
        self.dateStyles = dateStyles
    }

    static func parse(_ data: Data, shared: [String], dateStyles: Set<Int>) -> [[String]] {
        let delegate = WorksheetParser(shared: shared, dateStyles: dateStyles)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let last = delegate.rows.keys.max() else { return [] }
        return (0...last).map { index in
            guard let cells = delegate.rows[index], let width = cells.keys.max() else { return [] }
            return (0...width).map { cells[$0] ?? "" }
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
            column = 0
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
        case "t" where inInline:
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
        case "c":
            let text = display()
            if !text.isEmpty { rows[rowIndex, default: [:]][column] = text }
            column += 1
        default: break
        }
    }

    func display() -> String {
        switch cellType {
        case "s":
            guard let index = Int(value.trimmingCharacters(in: .whitespaces)), index < shared.count
            else { return "" }
            return shared[index]
        case "inlineStr": return inline
        case "b": return value == "1" ? "TRUE" : "FALSE"
        case "str", "e": return value
        default:
            guard let number = Double(value) else { return value }
            if dateStyles.contains(cellStyle) { return Self.date(fromSerial: number) }
            return Self.format(number)
        }
    }

    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.usesGroupingSeparator = false
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    static func date(fromSerial serial: Double) -> String {
        let base = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: 1899, month: 12, day: 30)
        guard let origin = base.date else { return format(serial) }
        let date = origin.addingTimeInterval(serial * 86_400)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = serial.rounded() == serial ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
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
