import Foundation
public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum InsertSide: String, Codable, Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    public var isBefore: Bool { self == .left || self == .top }
}
