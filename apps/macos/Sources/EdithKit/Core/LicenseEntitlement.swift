import CryptoKit
import Foundation

public struct LicenseEntitlement: Codable, Equatable, Sendable {
    public let version: Int
    public let keyId: String
    public let receiptId: String
    public let licenseId: String
    public let deviceId: String
    public let deviceKeyThumbprint: String
    public let productId: String
    public let planId: String
    public let maxMachines: Int
    public let features: [String]
    public let issuedAt: Int64
    public let notBefore: Int64
    public let expiresAt: Int64
    public let policyVersion: Int

    public init(
        version: Int, keyId: String, receiptId: String, licenseId: String, deviceId: String,
        deviceKeyThumbprint: String, productId: String, planId: String, maxMachines: Int,
        features: [String], issuedAt: Int64, notBefore: Int64, expiresAt: Int64,
        policyVersion: Int
    ) {
        self.version = version
        self.keyId = keyId
        self.receiptId = receiptId
        self.licenseId = licenseId
        self.deviceId = deviceId
        self.deviceKeyThumbprint = deviceKeyThumbprint
        self.productId = productId
        self.planId = planId
        self.maxMachines = maxMachines
        self.features = features
        self.issuedAt = issuedAt
        self.notBefore = notBefore
        self.expiresAt = expiresAt
        self.policyVersion = policyVersion
    }
}

public enum EntitlementValidation: Equatable {
    case valid(LicenseEntitlement)
    case expired(LicenseEntitlement)
    case notYetValid
    case unknownKey
    case invalid
}

public struct EntitlementVerifier {
    public static let productionKeys = [
        "edith-2026-07": LicenseReceiptVerifier.signingPublicKeyBase64
    ]

    private let trustedKeys: [String: Curve25519.Signing.PublicKey]

    public init(trustedKeys: [String: String] = EntitlementVerifier.productionKeys) {
        self.trustedKeys = trustedKeys.compactMapValues { encoded in
            guard let raw = Data(base64Encoded: encoded) else { return nil }
            return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        }
    }

    public func validation(
        entitlement: String, expectedDeviceId: String, expectedThumbprint: String, now: Date
    ) -> EntitlementValidation {
        let components = entitlement.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
            let payloadData = Base64URL.decode(String(components[0])),
            let signatureData = Base64URL.decode(String(components[1])),
            let payload = try? JSONDecoder().decode(LicenseEntitlement.self, from: payloadData)
        else {
            return .invalid
        }
        guard let key = trustedKeys[payload.keyId] else { return .unknownKey }
        guard key.isValidSignature(signatureData, for: payloadData),
            payload.version == 2,
            payload.productId == "edith",
            payload.deviceId == expectedDeviceId,
            payload.deviceKeyThumbprint == expectedThumbprint
        else {
            return .invalid
        }
        let timestamp = now.timeIntervalSince1970
        if timestamp < Double(payload.notBefore) { return .notYetValid }
        return timestamp < Double(payload.expiresAt) ? .valid(payload) : .expired(payload)
    }
}
