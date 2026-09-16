import Foundation

public enum BifrostDimension: String, CaseIterable, Codable, Sendable {
    case length
    case mass
    case temperature
    case time
    case data
    case speed
    case area
    case volume
    case angle

    public var title: String {
        switch self {
        case .length: "Length"
        case .mass: "Mass"
        case .temperature: "Temperature"
        case .time: "Time"
        case .data: "Data"
        case .speed: "Speed"
        case .area: "Area"
        case .volume: "Volume"
        case .angle: "Angle"
        }
    }
}

public struct BifrostUnit: Equatable, Sendable, Identifiable {
    public let id: String
    public let dimension: BifrostDimension
    public let symbol: String
    public let singular: String
    public let plural: String
    public let aliases: [String]
    public let factor: Double
    public let offset: Double

    init(
        _ id: String, _ dimension: BifrostDimension, symbol: String, singular: String,
        plural: String, aliases: [String], factor: Double, offset: Double = 0
    ) {
        self.id = id
        self.dimension = dimension
        self.symbol = symbol
        self.singular = singular
        self.plural = plural
        self.aliases = aliases
        self.factor = factor
        self.offset = offset
    }

    public func name(for value: Double) -> String {
        value == 1 ? singular : plural
    }
}

public enum BifrostUnitCatalog {
    public static let units: [BifrostUnit] =
        length + mass + temperature + time + data + speed
        + area + volume + angle

    public static func unit(id: String) -> BifrostUnit? {
        lookupByID[id]
    }

    public static func unit(alias: String) -> BifrostUnit? {
        let normalized = alias.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return nil }
        if let match = lookup[normalized] { return match }
        if normalized.hasSuffix("s"), let match = lookup[String(normalized.dropLast())] {
            return match
        }
        if normalized.hasSuffix("es"), let match = lookup[String(normalized.dropLast(2))] {
            return match
        }
        return nil
    }

    public static func convert(_ value: Double, from source: BifrostUnit, to target: BifrostUnit)
        -> Double?
    {
        guard source.dimension == target.dimension else { return nil }
        let base = value * source.factor + source.offset
        let converted = (base - target.offset) / target.factor
        return converted.isFinite ? converted : nil
    }

    public static func units(in dimension: BifrostDimension) -> [BifrostUnit] {
        units.filter { $0.dimension == dimension }
    }

    static let lookup: [String: BifrostUnit] = {
        var table: [String: BifrostUnit] = [:]
        for unit in units {
            for alias in [unit.id, unit.symbol, unit.singular, unit.plural] + unit.aliases {
                table[alias.lowercased()] = unit
            }
        }
        return table
    }()

    static let lookupByID: [String: BifrostUnit] = Dictionary(
        uniqueKeysWithValues: units.map { ($0.id, $0) })

    private static let length: [BifrostUnit] = [
        BifrostUnit(
            "nanometer", .length, symbol: "nm", singular: "nanometer", plural: "nanometers",
            aliases: ["nanometre", "nanometres"], factor: 1e-9),
        BifrostUnit(
            "micrometer", .length, symbol: "µm", singular: "micrometer", plural: "micrometers",
            aliases: ["um", "micron", "microns", "micrometre", "micrometres"], factor: 1e-6),
        BifrostUnit(
            "millimeter", .length, symbol: "mm", singular: "millimeter", plural: "millimeters",
            aliases: ["millimetre", "millimetres"], factor: 0.001),
        BifrostUnit(
            "centimeter", .length, symbol: "cm", singular: "centimeter", plural: "centimeters",
            aliases: ["centimetre", "centimetres"], factor: 0.01),
        BifrostUnit(
            "meter", .length, symbol: "m", singular: "meter", plural: "meters",
            aliases: ["metre", "metres"], factor: 1),
        BifrostUnit(
            "kilometer", .length, symbol: "km", singular: "kilometer", plural: "kilometers",
            aliases: ["kilometre", "kilometres", "kms"], factor: 1000),
        BifrostUnit(
            "inch", .length, symbol: "in", singular: "inch", plural: "inches",
            aliases: ["\""], factor: 0.0254),
        BifrostUnit(
            "foot", .length, symbol: "ft", singular: "foot", plural: "feet",
            aliases: ["'"], factor: 0.3048),
        BifrostUnit(
            "yard", .length, symbol: "yd", singular: "yard", plural: "yards", aliases: [],
            factor: 0.9144),
        BifrostUnit(
            "mile", .length, symbol: "mi", singular: "mile", plural: "miles", aliases: ["miles"],
            factor: 1609.344),
        BifrostUnit(
            "nautical-mile", .length, symbol: "nmi", singular: "nautical mile",
            plural: "nautical miles", aliases: ["nauticalmile"], factor: 1852),
    ]

    private static let mass: [BifrostUnit] = [
        BifrostUnit(
            "milligram", .mass, symbol: "mg", singular: "milligram", plural: "milligrams",
            aliases: [], factor: 0.001),
        BifrostUnit(
            "gram", .mass, symbol: "g", singular: "gram", plural: "grams",
            aliases: ["gramme", "grammes"], factor: 1),
        BifrostUnit(
            "kilogram", .mass, symbol: "kg", singular: "kilogram", plural: "kilograms",
            aliases: ["kilo", "kilos", "kilogramme"], factor: 1000),
        BifrostUnit(
            "tonne", .mass, symbol: "t", singular: "tonne", plural: "tonnes",
            aliases: ["metricton", "metric ton"], factor: 1_000_000),
        BifrostUnit(
            "ounce", .mass, symbol: "oz", singular: "ounce", plural: "ounces", aliases: [],
            factor: 28.349523125),
        BifrostUnit(
            "pound", .mass, symbol: "lb", singular: "pound", plural: "pounds",
            aliases: ["lbs"], factor: 453.59237),
        BifrostUnit(
            "stone", .mass, symbol: "st", singular: "stone", plural: "stones", aliases: [],
            factor: 6350.29318),
    ]

    private static let temperature: [BifrostUnit] = [
        BifrostUnit(
            "celsius", .temperature, symbol: "°C", singular: "degree Celsius",
            plural: "degrees Celsius", aliases: ["c", "centigrade", "degc", "°c"], factor: 1,
            offset: 273.15),
        BifrostUnit(
            "fahrenheit", .temperature, symbol: "°F", singular: "degree Fahrenheit",
            plural: "degrees Fahrenheit", aliases: ["f", "degf", "°f"], factor: 5.0 / 9.0,
            offset: 255.372222222222),
        BifrostUnit(
            "kelvin", .temperature, symbol: "K", singular: "kelvin", plural: "kelvin",
            aliases: ["k"], factor: 1),
    ]

    private static let time: [BifrostUnit] = [
        BifrostUnit(
            "nanosecond", .time, symbol: "ns", singular: "nanosecond", plural: "nanoseconds",
            aliases: [], factor: 1e-9),
        BifrostUnit(
            "millisecond", .time, symbol: "ms", singular: "millisecond", plural: "milliseconds",
            aliases: [], factor: 0.001),
        BifrostUnit(
            "second", .time, symbol: "s", singular: "second", plural: "seconds",
            aliases: ["sec", "secs"], factor: 1),
        BifrostUnit(
            "minute", .time, symbol: "min", singular: "minute", plural: "minutes",
            aliases: ["mins"], factor: 60),
        BifrostUnit(
            "hour", .time, symbol: "h", singular: "hour", plural: "hours",
            aliases: ["hr", "hrs"], factor: 3600),
        BifrostUnit(
            "day", .time, symbol: "d", singular: "day", plural: "days", aliases: [],
            factor: 86400),
        BifrostUnit(
            "week", .time, symbol: "wk", singular: "week", plural: "weeks", aliases: [],
            factor: 604_800),
    ]

    private static let data: [BifrostUnit] = [
        BifrostUnit(
            "bit", .data, symbol: "bit", singular: "bit", plural: "bits", aliases: ["b"],
            factor: 0.125),
        BifrostUnit(
            "byte", .data, symbol: "B", singular: "byte", plural: "bytes", aliases: [],
            factor: 1),
        BifrostUnit(
            "kilobyte", .data, symbol: "kB", singular: "kilobyte", plural: "kilobytes",
            aliases: ["kb"], factor: 1000),
        BifrostUnit(
            "megabyte", .data, symbol: "MB", singular: "megabyte", plural: "megabytes",
            aliases: ["mb"], factor: 1_000_000),
        BifrostUnit(
            "gigabyte", .data, symbol: "GB", singular: "gigabyte", plural: "gigabytes",
            aliases: ["gb"], factor: 1_000_000_000),
        BifrostUnit(
            "terabyte", .data, symbol: "TB", singular: "terabyte", plural: "terabytes",
            aliases: ["tb"], factor: 1e12),
        BifrostUnit(
            "kibibyte", .data, symbol: "KiB", singular: "kibibyte", plural: "kibibytes",
            aliases: ["kib"], factor: 1024),
        BifrostUnit(
            "mebibyte", .data, symbol: "MiB", singular: "mebibyte", plural: "mebibytes",
            aliases: ["mib"], factor: 1_048_576),
        BifrostUnit(
            "gibibyte", .data, symbol: "GiB", singular: "gibibyte", plural: "gibibytes",
            aliases: ["gib"], factor: 1_073_741_824),
        BifrostUnit(
            "tebibyte", .data, symbol: "TiB", singular: "tebibyte", plural: "tebibytes",
            aliases: ["tib"], factor: 1_099_511_627_776),
    ]

    private static let speed: [BifrostUnit] = [
        BifrostUnit(
            "meter-per-second", .speed, symbol: "m/s", singular: "meter per second",
            plural: "meters per second", aliases: ["mps", "m per s"], factor: 1),
        BifrostUnit(
            "kilometer-per-hour", .speed, symbol: "km/h", singular: "kilometer per hour",
            plural: "kilometers per hour", aliases: ["kmh", "kph", "kmph"], factor: 1 / 3.6),
        BifrostUnit(
            "mile-per-hour", .speed, symbol: "mph", singular: "mile per hour",
            plural: "miles per hour", aliases: ["mi/h"], factor: 0.44704),
        BifrostUnit(
            "foot-per-second", .speed, symbol: "ft/s", singular: "foot per second",
            plural: "feet per second", aliases: ["fps"], factor: 0.3048),
        BifrostUnit(
            "knot", .speed, symbol: "kn", singular: "knot", plural: "knots", aliases: ["kt"],
            factor: 0.514444444444444),
    ]

    private static let area: [BifrostUnit] = [
        BifrostUnit(
            "square-meter", .area, symbol: "m²", singular: "square meter",
            plural: "square meters", aliases: ["m2", "sqm", "sq m"], factor: 1),
        BifrostUnit(
            "square-kilometer", .area, symbol: "km²", singular: "square kilometer",
            plural: "square kilometers", aliases: ["km2", "sqkm"], factor: 1_000_000),
        BifrostUnit(
            "square-foot", .area, symbol: "ft²", singular: "square foot",
            plural: "square feet", aliases: ["ft2", "sqft", "sq ft"], factor: 0.09290304),
        BifrostUnit(
            "square-mile", .area, symbol: "mi²", singular: "square mile",
            plural: "square miles", aliases: ["mi2", "sqmi"], factor: 2_589_988.110336),
        BifrostUnit(
            "hectare", .area, symbol: "ha", singular: "hectare", plural: "hectares",
            aliases: [], factor: 10000),
        BifrostUnit(
            "acre", .area, symbol: "ac", singular: "acre", plural: "acres", aliases: [],
            factor: 4046.8564224),
    ]

    private static let volume: [BifrostUnit] = [
        BifrostUnit(
            "milliliter", .volume, symbol: "ml", singular: "milliliter", plural: "milliliters",
            aliases: ["millilitre", "millilitres"], factor: 0.001),
        BifrostUnit(
            "liter", .volume, symbol: "l", singular: "liter", plural: "liters",
            aliases: ["litre", "litres"], factor: 1),
        BifrostUnit(
            "cubic-meter", .volume, symbol: "m³", singular: "cubic meter",
            plural: "cubic meters", aliases: ["m3"], factor: 1000),
        BifrostUnit(
            "teaspoon", .volume, symbol: "tsp", singular: "teaspoon", plural: "teaspoons",
            aliases: [], factor: 0.00492892159375),
        BifrostUnit(
            "tablespoon", .volume, symbol: "tbsp", singular: "tablespoon",
            plural: "tablespoons", aliases: [], factor: 0.01478676478125),
        BifrostUnit(
            "cup", .volume, symbol: "cup", singular: "cup", plural: "cups", aliases: [],
            factor: 0.2365882365),
        BifrostUnit(
            "fluid-ounce", .volume, symbol: "fl oz", singular: "fluid ounce",
            plural: "fluid ounces", aliases: ["floz", "fluidounce"], factor: 0.0295735295625),
        BifrostUnit(
            "pint", .volume, symbol: "pt", singular: "pint", plural: "pints", aliases: [],
            factor: 0.473176473),
        BifrostUnit(
            "quart", .volume, symbol: "qt", singular: "quart", plural: "quarts", aliases: [],
            factor: 0.946352946),
        BifrostUnit(
            "gallon", .volume, symbol: "gal", singular: "gallon", plural: "gallons",
            aliases: [], factor: 3.785411784),
    ]

    private static let angle: [BifrostUnit] = [
        BifrostUnit(
            "degree", .angle, symbol: "°", singular: "degree", plural: "degrees",
            aliases: ["deg"], factor: 1),
        BifrostUnit(
            "radian", .angle, symbol: "rad", singular: "radian", plural: "radians",
            aliases: [], factor: 180 / Double.pi),
        BifrostUnit(
            "gradian", .angle, symbol: "grad", singular: "gradian", plural: "gradians",
            aliases: ["gon"], factor: 0.9),
        BifrostUnit(
            "turn", .angle, symbol: "turn", singular: "turn", plural: "turns", aliases: [],
            factor: 360),
    ]
}
