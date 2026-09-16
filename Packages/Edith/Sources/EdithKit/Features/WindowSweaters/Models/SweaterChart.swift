import Foundation

public struct SweaterChart: Equatable, Sendable, Identifiable {
    public let name: String
    public let width: Int
    public let height: Int
    public let cells: [UInt32]
    public let solidCorners: Bool
    public let cornerColor: UInt32
    public let cuffColor: UInt32
    public let roundDots: Bool
    public let fittedRepeat: Bool
    public let sculptedYarn: Bool
    public let definedYarn: Bool

    public var id: String { name }

    public init(
        name: String, width: Int, height: Int, cells: [UInt32],
        solidCorners: Bool = false, cornerColor: UInt32 = 0, cuffColor: UInt32 = 0,
        roundDots: Bool = false, fittedRepeat: Bool = false,
        sculptedYarn: Bool = true, definedYarn: Bool = true
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.cells = cells
        self.solidCorners = solidCorners
        self.cornerColor = cornerColor
        self.cuffColor = cuffColor
        self.roundDots = roundDots
        self.fittedRepeat = fittedRepeat
        self.sculptedYarn = sculptedYarn
        self.definedYarn = definedYarn
    }

    public func cell(row: Int, column: Int) -> UInt32 {
        let y = ((row % height) + height) % height
        let x = ((column % width) + width) % width
        return cells[y * width + x]
    }
}

struct SweaterChartSpec {
    let name: String
    let rows: [String]
    let yarn: [UInt32]
}

public enum SweaterChartCatalog {
    static let roundDotCharts: Set<String> = ["atelier-messages"]

    static let fittedRepeatCharts: Set<String> = [
        "atelier-finder", "atelier-terminal", "atelier-grok", "atelier-granola",
        "atelier-illustrator", "atelier-chrome",
    ]

    static let cuffCharts: Set<String> = ["atelier-notes", "atelier-calendar"]

    static let solidCornerCharts: [String: UInt32] = ["atelier-whatsapp": 0]

    public static let builtIn: [SweaterChart] = specs.map(chart(from:))

    public static let byName: [String: SweaterChart] = Dictionary(
        uniqueKeysWithValues: builtIn.map { ($0.name, $0) })

    public static func chart(named name: String) -> SweaterChart? { byName[name] }

    public static func index(of name: String) -> Int? {
        builtIn.firstIndex { $0.name == name }
    }

    static func chart(from spec: SweaterChartSpec) -> SweaterChart {
        let width = spec.rows[0].count
        let height = spec.rows.count
        var cells = [UInt32](repeating: 0, count: width * height)
        for (y, row) in spec.rows.enumerated() {
            for (x, symbol) in row.unicodeScalars.enumerated() where symbol != "." {
                guard let slot = symbol.knitYarnSlot, slot < spec.yarn.count else { continue }
                cells[y * width + x] = spec.yarn[slot]
            }
        }
        var cuffColor: UInt32 = 0
        if cuffCharts.contains(spec.name), let first = spec.yarn.first {
            cuffColor = first
            for index in cells.indices where cells[index] == cuffColor { cells[index] = 0 }
        }
        let roundDots = roundDotCharts.contains(spec.name)
        let cornerColor = solidCornerCharts[spec.name]
        return SweaterChart(
            name: spec.name, width: width, height: height, cells: cells,
            solidCorners: cornerColor != nil, cornerColor: cornerColor ?? 0,
            cuffColor: cuffColor, roundDots: roundDots,
            fittedRepeat: fittedRepeatCharts.contains(spec.name),
            sculptedYarn: !roundDots, definedYarn: true)
    }
}

extension Unicode.Scalar {
    var knitYarnSlot: Int? {
        guard value >= UInt32(UInt8(ascii: "a")), value <= UInt32(UInt8(ascii: "f"))
        else { return nil }
        return Int(value - UInt32(UInt8(ascii: "a")))
    }
}
