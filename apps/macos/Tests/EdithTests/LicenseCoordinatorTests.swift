import CryptoKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct LicenseCoordinatorTests {
    private let signingKey = Curve25519.Signing.PrivateKey()
    private let deviceId = "device-1"
    private let thumbprint = "thumb-1"
    private let expiresAt: Int64 = 1_750_000_000

    @Test func noEntitlementAndNoLegacyReceiptIsNoLicense() {
        let coordinator = makeCoordinator(store: InMemoryLicenseCredentialStore())

        #expect(state(coordinator, now: expiresAt) == .noLicense)
    }

    @Test func validLegacyReceiptFallsBackToLegacyV1() {
        let coordinator = makeCoordinator(
            store: InMemoryLicenseCredentialStore(), legacyValidation: { .valid })

        #expect(state(coordinator, now: expiresAt) == .legacyV1(needsMigration: true))
    }

    @Test func expiredOrInvalidLegacyReceiptIsNoLicense() {
        let expired = makeCoordinator(
            store: InMemoryLicenseCredentialStore(), legacyValidation: { .expired })
        let invalid = makeCoordinator(
            store: InMemoryLicenseCredentialStore(), legacyValidation: { .invalid })

        #expect(state(expired, now: expiresAt) == .noLicense)
        #expect(state(invalid, now: expiresAt) == .noLicense)
    }

    @Test func entitlementTakesPrecedenceOverLegacyReceipt() throws {
        let store = try storeWithEntitlement()
        let coordinator = makeCoordinator(store: store, legacyValidation: { .valid })

        #expect(state(coordinator, now: expiresAt - 1_000) == .valid(makePayload()))
    }

    @Test func unexpiredEntitlementWithPlausibleTimeIsValid() throws {
        let coordinator = makeCoordinator(store: try storeWithEntitlement())

        #expect(state(coordinator, now: expiresAt - 1) == .valid(makePayload()))
    }

    @Test func rollbackSuspicionCapsValidEntitlementAtGrace() throws {
        let store = try storeWithEntitlement()
        try TrustedTime(
            lastServerTime: expiresAt + 10 * 86_400, wallClockAtSync: expiresAt + 10 * 86_400,
            monotonicAnchor: 100, bootSessionId: "boot-1"
        ).save(to: store)
        let coordinator = makeCoordinator(store: store)

        #expect(
            state(coordinator, now: expiresAt - 1_000)
                == .graceActive(remainingDays: 30, warn: false))
    }

    @Test func expiryEntersSilentGrace() throws {
        let coordinator = makeCoordinator(store: try storeWithEntitlement())

        #expect(
            state(coordinator, now: expiresAt) == .graceActive(remainingDays: 30, warn: false))
        #expect(
            state(coordinator, now: expiresAt + 86_400)
                == .graceActive(remainingDays: 29, warn: false))
        #expect(
            state(coordinator, now: expiresAt + 24 * 86_400 + 86_399)
                == .graceActive(remainingDays: 6, warn: false))
    }

    @Test func lastFiveGraceDaysWarn() throws {
        let coordinator = makeCoordinator(store: try storeWithEntitlement())

        #expect(
            state(coordinator, now: expiresAt + 25 * 86_400)
                == .graceActive(remainingDays: 5, warn: true))
        #expect(
            state(coordinator, now: expiresAt + 29 * 86_400)
                == .graceActive(remainingDays: 1, warn: true))
    }

    @Test func exhaustedGraceEntersRecovery() throws {
        let coordinator = makeCoordinator(store: try storeWithEntitlement())

        #expect(state(coordinator, now: expiresAt + 30 * 86_400) == .recovery)
        #expect(state(coordinator, now: expiresAt + 365 * 86_400) == .recovery)
    }

    @Test func customGraceDaysShiftBoundaries() throws {
        let coordinator = makeCoordinator(store: try storeWithEntitlement(), graceDays: 7)

        #expect(
            state(coordinator, now: expiresAt + 2 * 86_400)
                == .graceActive(remainingDays: 5, warn: true))
        #expect(state(coordinator, now: expiresAt + 7 * 86_400) == .recovery)
    }

    @Test func tamperedEntitlementIsRevoked() throws {
        let store = InMemoryLicenseCredentialStore()
        let entitlement = try sign(makePayload())
        let signaturePart = entitlement.split(separator: ".")[1]
        let tamperedPayload = try JSONEncoder().encode(makePayload(maxMachines: 99))
        try store.write(
            "\(Base64URL.encode(tamperedPayload)).\(signaturePart)", item: .entitlement)
        let coordinator = makeCoordinator(store: store)

        #expect(state(coordinator, now: expiresAt - 1_000) == .revoked)
    }

    @Test func wrongDeviceEntitlementIsRevoked() throws {
        let coordinator = makeCoordinator(store: try storeWithEntitlement())

        let result = coordinator.riskState(
            deviceId: "other-device", deviceKeyThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: Double(expiresAt - 1_000)))
        #expect(result == .revoked)
    }

    @Test func unknownKeyIdEntersRecovery() throws {
        let store = InMemoryLicenseCredentialStore()
        try store.write(try sign(makePayload(keyId: "rotated-key")), item: .entitlement)
        let coordinator = makeCoordinator(store: store)

        #expect(state(coordinator, now: expiresAt - 1_000) == .recovery)
    }

    @Test func notYetValidEntitlementEntersRecovery() throws {
        let store = InMemoryLicenseCredentialStore()
        try store.write(
            try sign(makePayload(notBefore: expiresAt - 100)), item: .entitlement)
        let coordinator = makeCoordinator(store: store)

        #expect(state(coordinator, now: expiresAt - 1_000) == .recovery)
    }

    private func state(_ coordinator: LicenseCoordinator, now: Int64) -> LicenseRiskState {
        coordinator.riskState(
            deviceId: deviceId, deviceKeyThumbprint: thumbprint,
            now: Date(timeIntervalSince1970: Double(now)))
    }

    private func makeCoordinator(
        store: any LicenseCredentialStoring,
        legacyValidation: @escaping () -> LicenseReceiptValidation? = { nil },
        graceDays: Int = 30
    ) -> LicenseCoordinator {
        LicenseCoordinator(
            store: store,
            verifier: EntitlementVerifier(trustedKeys: [
                "test-key": signingKey.publicKey.rawRepresentation.base64EncodedString()
            ]),
            legacyValidation: legacyValidation,
            graceDays: graceDays)
    }

    private func storeWithEntitlement() throws -> InMemoryLicenseCredentialStore {
        let store = InMemoryLicenseCredentialStore()
        try store.write(try sign(makePayload()), item: .entitlement)
        return store
    }

    private func makePayload(
        keyId: String = "test-key", maxMachines: Int = 3, notBefore: Int64 = 1_700_000_000
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
