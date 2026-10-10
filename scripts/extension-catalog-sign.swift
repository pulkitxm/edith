import CryptoKit
import Foundation

let arguments = CommandLine.arguments
if arguments.count == 3 && arguments[1] == "generate-key" {
    let key = Curve25519.Signing.PrivateKey()
    let destination = URL(fileURLWithPath: arguments[2])
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedData().write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else if arguments.count == 5 && arguments[1] == "verify" {
    guard let publicKey = Data(base64Encoded: arguments[4]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let envelope = try JSONDecoder().decode([String: String].self, from: data)
    guard let encodedPayload = envelope["payload"],
        let payload = Data(base64Encoded: encodedPayload),
        let encodedSignature = envelope["signature"],
        let signature = Data(base64Encoded: encodedSignature),
        try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(
            signature, for: payload)
    else { throw CocoaError(.fileReadCorruptFile) }
    try payload.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
} else if arguments.count == 4 && arguments[1] == "sign" {
    guard let encodedKey = ProcessInfo.processInfo.environment["EXTENSION_CATALOG_PRIVATE_KEY"],
        let rawKey = Data(base64Encoded: encodedKey)
    else {
        throw NSError(
            domain: "ExtensionCatalog", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "An extension catalog signing key is required."])
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    let payload = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let signature = try key.signature(for: payload)
    let envelope = [
        "payload": payload.base64EncodedString(), "signature": signature.base64EncodedString(),
    ]
    try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(
        to: URL(fileURLWithPath: arguments[3]), options: .atomic)
} else {
    throw NSError(
        domain: "ExtensionCatalog", code: 2,
        userInfo: [
            NSLocalizedDescriptionKey:
                "Use generate-key <private-key-path> or sign <payload-path> <envelope-path> or verify <envelope-path> <payload-path> <public-key>."
        ])
}
