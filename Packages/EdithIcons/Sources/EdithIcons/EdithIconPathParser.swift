import SwiftUI

enum EdithIconPathParser {
    static func path(from data: String) -> Path {
        var path = Path()
        var scanner = NumberScanner(bytes: Array(data.utf8))
        var current = CGPoint.zero
        while let command = scanner.nextCommand() {
            switch command {
            case UInt8(ascii: "M"):
                current = scanner.point()
                path.move(to: current)
            case UInt8(ascii: "L"):
                current = scanner.point()
                path.addLine(to: current)
            case UInt8(ascii: "H"):
                current.x = scanner.number()
                path.addLine(to: current)
            case UInt8(ascii: "V"):
                current.y = scanner.number()
                path.addLine(to: current)
            case UInt8(ascii: "Q"):
                let control = scanner.point()
                current = scanner.point()
                path.addQuadCurve(to: current, control: control)
            case UInt8(ascii: "C"):
                let first = scanner.point()
                let second = scanner.point()
                current = scanner.point()
                path.addCurve(to: current, control1: first, control2: second)
            default:
                path.closeSubpath()
            }
        }
        return path
    }
}

private struct NumberScanner {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func nextCommand() -> UInt8? {
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { return byte }
        }
        return nil
    }

    mutating func point() -> CGPoint {
        let x = number()
        return CGPoint(x: x, y: number())
    }

    mutating func number() -> CGFloat {
        while index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }
        let start = index
        while index < bytes.count, Self.isNumeric(bytes[index]) { index += 1 }
        return CGFloat(Double(String(decoding: bytes[start..<index], as: UTF8.self)) ?? 0)
    }

    private static func isNumeric(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "-")
    }
}
