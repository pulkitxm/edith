import Foundation

public struct ExtensionSystemVersion: Codable, Comparable, Hashable, Sendable,
    CustomStringConvertible
{
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        precondition([major, minor, patch].allSatisfy { (0...Int(Int32.max)).contains($0) })
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(_ version: OperatingSystemVersion) {
        self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 10,
                part == "0" || !part.hasPrefix("0"),
                part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let number = Int(part), number <= Int(Int32.max)
            else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let version = Self(value) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid system version")
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
