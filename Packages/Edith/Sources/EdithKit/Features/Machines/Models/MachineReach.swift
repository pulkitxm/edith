import Darwin
import Foundation

public enum MachineReach: Equatable, Sendable {
    case local
    case remote

    public init(host: String) {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        let address = name.split(separator: "%", maxSplits: 1).first.map(String.init) ?? name
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".localhost") {
            self = .local
        } else if let bytes = Self.bytes(of: address, family: AF_INET, length: 4) {
            self = Self.isPrivateIPv4(bytes) ? .local : .remote
        } else if let bytes = Self.bytes(of: address, family: AF_INET6, length: 16) {
            self = Self.isPrivateIPv6(bytes) ? .local : .remote
        } else {
            self = .remote
        }
    }

    public var connectTimeout: Int {
        switch self {
        case .local: 3
        case .remote: 6
        }
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): true
        case (172, 16...31): true
        default: false
        }
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        return bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
    }

    private static func bytes(of text: String, family: Int32, length: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: length)
        let parsed = buffer.withUnsafeMutableBytes { inet_pton(family, text, $0.baseAddress) }
        return parsed == 1 ? buffer : nil
    }
}

extension Machine {
    public var reach: MachineReach { MachineReach(host: host) }
}
