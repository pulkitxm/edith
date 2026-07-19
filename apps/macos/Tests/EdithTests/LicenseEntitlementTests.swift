import CryptoKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct LicenseEntitlementTests {
    private let signingKey = Curve25519.Signing.PrivateKey()
    private let deviceId = "device-1"
    private let thumbprint = "thumb-1"

    @Test func acceptsValidEntitlement() throws {
        let payload = makePayload()
        let entitlement = try sign(payload)

        let result = verifier().validation(
            entitlement: entitlement, expectedDeviceId: deviceId, expectedThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .valid(payload))
    }

    @Test func reportsExpiredEntitlement() throws {
        let payload = makePayload(expiresAt: 1_700_000_000)
        let entitlement = try sign(payload)

        let result = verifier().validation(
            entitlement: entitlement, expectedDeviceId: deviceId, expectedThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .expired(payload))
    }

    @Test func reportsNotYetValidEntitlement() throws {
        let entitlement = try sign(makePayload(notBefore: 1_760_000_000))

        let result = verifier().validation(
            entitlement: entitlement, expectedDeviceId: deviceId, expectedThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .notYetValid)
    }

    @Test func rejectsWrongDevice() throws {
        let entitlement = try sign(makePayload())

        let result = verifier().validation(
            entitlement: entitlement, expectedDeviceId: "other-device",
            expectedThumbprint: thumbprint, now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .invalid)
    }

    @Test func rejectsWrongThumbprint() throws {
        let entitlement = try sign(makePayload())

        let result = verifier().validation(
            entitlement: entitlement, expectedDeviceId: deviceId,
            expectedThumbprint: "other-thumb", now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .invalid)
    }

    @Test func reportsUnknownKeyId() throws {
        let entitlement = try sign(makePayload(keyId: "rotated-key"))

        let result = verifier().validation(
            entitlement: entitlement, expectedDeviceId: deviceId, expectedThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .unknownKey)
    }

    @Test func rejectsTamperedPayload() throws {
        let entitlement = try sign(makePayload())
        let signaturePart = entitlement.split(separator: ".")[1]
        let tamperedPayload = try JSONEncoder().encode(makePayload(maxMachines: 99))
        let tampered = "\(Base64URL.encode(tamperedPayload)).\(signaturePart)"

        let result = verifier().validation(
            entitlement: tampered, expectedDeviceId: deviceId, expectedThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: 1_750_000_000))

        #expect(result == .invalid)
    }

    @Test func rejectsMalformedEntitlement() {
        let malformed = ["", "abc", "abc.def.ghi", "abc=.def"]
        for entitlement in malformed {
            let result = verifier().validation(
                entitlement: entitlement, expectedDeviceId: deviceId,
                expectedThumbprint: thumbprint, now: Date(timeIntervalSince1970: 1_750_000_000))
            #expect(result == .invalid)
        }
    }

    private func verifier() -> EntitlementVerifier {
        EntitlementVerifier(trustedKeys: [
            "test-key": signingKey.publicKey.rawRepresentation.base64EncodedString()
        ])
    }

    private func makePayload(
        keyId: String = "test-key", maxMachines: Int = 3, notBefore: Int64 = 1_700_000_000,
        expiresAt: Int64 = 1_800_000_000
    ) -> LicenseEntitlement {
        LicenseEntitlement(
            version: 2, keyId: keyId, receiptId: "receipt-1", licenseId: "license-1",
            deviceId: deviceId, deviceKeyThumbprint: thumbprint, productId: "edith",
            planId: "personal_3", maxMachines: maxMachines, features: ["edith-core"],
            issuedAt: 1_700_000_000, notBefore: notBefore, expiresAt: expiresAt,
            policyVersion: 2)
    }

    private func sign(_ payload: LicenseEntitlement) throws -> String {
        let data = try JSONEncoder().encode(payload)
        let signature = try signingKey.signature(for: data)
        return "\(Base64URL.encode(data)).\(Base64URL.encode(signature))"
    }
}
