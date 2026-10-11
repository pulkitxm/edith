import CoreFoundation
import CryptoKit
import Foundation

enum FunctionalFailure: Error {
    case invalid(String)
    case timeout(String)
    case unavailable(String)
}

enum FunctionalBytes {
    static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    static func object(_ bytes: Data, maximum: Int = 1_048_576) throws -> [String: Any] {
        guard !bytes.isEmpty, bytes.count <= maximum,
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            try canonical(object) == bytes
        else { throw FunctionalFailure.invalid("canonical object") }
        return object
    }

    static func exact(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw FunctionalFailure.invalid("closed fields") }
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func uuid(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value && value.utf8.count == 36
            && value[value.index(value.startIndex, offsetBy: 14)] == "4"
            && "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)])
    }

    static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.intValue)
        else { throw FunctionalFailure.invalid("integer") }
        return number.intValue
    }
}

final class FunctionalIssuer {
    private let key = Curve25519.Signing.PrivateKey()
    let sourceCommit: String
    let session: String

    init(sourceCommit: String, session: String) throws {
        guard FunctionalBytes.hex(sourceCommit, length: 40), FunctionalBytes.uuid(session)
        else { throw FunctionalFailure.invalid("issuer scope") }
        self.sourceCommit = sourceCommit
        self.session = session
    }

    var publicKey: Data { key.publicKey.rawRepresentation }

    func seal(_ observed: [String: Any]) throws -> Data {
        guard observed["sourceCommit"] as? String == sourceCommit,
            observed["session"] as? String == session,
            try FunctionalBytes.integer(observed, "schema") == 1
        else { throw FunctionalFailure.invalid("observation scope") }
        let bytes = try FunctionalBytes.canonical(observed)
        guard bytes.count <= 1_048_576, let payload = String(data: bytes, encoding: .utf8)
        else { throw FunctionalFailure.invalid("observation size") }
        return try FunctionalBytes.canonical([
            "schema": 1, "payload": payload,
            "signature": try key.signature(for: bytes).base64EncodedString(),
        ])
    }
}
