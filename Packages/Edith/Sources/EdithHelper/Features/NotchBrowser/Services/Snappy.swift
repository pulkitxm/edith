import Foundation

enum SnappyError: Error, Equatable {
    case truncated, invalidOffset, lengthMismatch
}

enum Snappy {
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var position = 0

        func read(_ count: Int) throws -> UInt64 {
            guard count <= bytes.count - position else { throw SnappyError.truncated }
            var value: UInt64 = 0
            for index in 0..<count {
                value |= UInt64(bytes[position + index]) << (index * 8)
            }
            position += count
            return value
        }

        var declared: UInt64 = 0
        for index in 0..<5 {
            let byte = try read(1)
            if index == 4 && byte > 15 { throw SnappyError.lengthMismatch }
            declared |= (byte & 127) << (index * 7)
            if byte & 128 == 0 { break }
        }
        let expected = Int(declared)
        var output: [UInt8] = []
        output.reserveCapacity(min(expected, bytes.count * 8))
        while position < bytes.count {
            let tag = Int(try read(1))
            let kind = tag & 3
            let length: Int
            if kind == 0 {
                let encoded = tag >> 2
                length = encoded < 60 ? encoded + 1 : Int(try read(encoded - 59)) + 1
                guard length <= bytes.count - position else { throw SnappyError.truncated }
                guard length <= expected - output.count else { throw SnappyError.lengthMismatch }
                output.append(contentsOf: bytes[position..<(position + length)])
                position += length
            } else {
                let offset: Int
                if kind == 1 {
                    length = 4 + ((tag >> 2) & 7)
                    offset = ((tag >> 5) << 8) | Int(try read(1))
                } else {
                    length = 1 + (tag >> 2)
                    offset = Int(try read(kind == 2 ? 2 : 4))
                }
                guard offset > 0, offset <= output.count else { throw SnappyError.invalidOffset }
                guard length <= expected - output.count else { throw SnappyError.lengthMismatch }
                for _ in 0..<length {
                    output.append(output[output.count - offset])
                }
            }
        }
        guard output.count == expected else { throw SnappyError.lengthMismatch }
        return Data(output)
    }
}
