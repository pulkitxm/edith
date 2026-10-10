import CryptoKit
import Darwin
import Foundation

@main
enum HostReleaseSignature {
    static func main() {
        do { try verify() } catch { exit(1) }
    }

    static func verify() throws {
        guard CommandLine.arguments.count == 4,
            let key = Data(base64Encoded: CommandLine.arguments[1]), key.count == 32,
            let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64
        else { throw CocoaError(.fileReadCorruptFile) }
        let url = URL(fileURLWithPath: CommandLine.arguments[3])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.int64Value > 0,
            size.int64Value <= 1_073_741_824
        else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count == size.intValue,
            try Curve25519.Signing.PublicKey(rawRepresentation: key)
                .isValidSignature(signature, for: bytes)
        else { throw CocoaError(.fileReadCorruptFile) }
    }
}
