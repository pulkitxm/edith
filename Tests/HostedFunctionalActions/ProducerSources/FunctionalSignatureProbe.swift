import CryptoKit
import Foundation
import Security

@main enum FunctionalSignatureProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
            let expectedCertificate = Data(base64Encoded: arguments[3]),
            expectedCertificate.count == 32,
            expectedCertificate.base64EncodedString() == arguments[3],
            arguments[1].hasPrefix("/"), !arguments[1].utf8.contains(0)
        else { throw CocoaError(.fileReadCorruptFile) }
        let url = URL(fileURLWithPath: arguments[1])
        guard url.path == url.standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().path
        else { throw CocoaError(.fileReadCorruptFile) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
            let code,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(
                    rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode
                        | kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { throw CocoaError(.fileReadCorruptFile) }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let values = information as? [String: Any],
            values[kSecCodeInfoIdentifier as String] as? String == arguments[2],
            let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { throw CocoaError(.fileReadCorruptFile) }
        let certificate = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        guard certificate == expectedCertificate else { throw CocoaError(.fileReadCorruptFile) }
        let result = [
            "identifier": arguments[2], "certificateSHA256": certificate.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
    }
}
