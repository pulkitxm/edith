import CryptoKit
import Foundation
import Testing

@testable import EdithKit

@Suite struct LicenseLaunchDecisionTests {
    private let payload = LicenseEntitlement(
        version: 2, keyId: "edith-2026-07", receiptId: "r-1", licenseId: "l-1",
        deviceId: "device-1", deviceKeyThumbprint: "thumb-1", productId: "edith",
        planId: "personal_3", maxMachines: 3, features: ["edith-core"], issuedAt: 0,
        notBefore: 0, expiresAt: 100, policyVersion: 2)

    @Test func validAndGraceStart() {
        #expect(LicenseRiskState.valid(payload).launchDecision == .start)
        #expect(
            LicenseRiskState.graceActive(remainingDays: 3, warn: true).launchDecision == .start)
    }

    @Test func legacyV1StartsAndMigrates() {
        #expect(
            LicenseRiskState.legacyV1(needsMigration: true).launchDecision == .startAndMigrate)
    }

    @Test func recoveryRevokedAndNoLicenseGate() {
        #expect(LicenseRiskState.recovery.launchDecision == .gate)
        #expect(LicenseRiskState.revoked.launchDecision == .gate)
        #expect(LicenseRiskState.noLicense.launchDecision == .gate)
    }
}

@Suite struct LicenseUpdaterHeaderTests {
    private let now = Date(timeIntervalSince1970: 1_752_000_000)

    private func iso(offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    @Test func freshTokenUsesBearerHeader() {
        let headers = licenseUpdaterHeaders(
            accessToken: StoredAccessToken(token: "tok", expiresAt: iso(offset: 600)),
            legacyKey: "EDITH-ABCD", machine: "hardware-1", now: now)

        #expect(headers == ["Authorization": "Bearer tok"])
    }

    @Test func fractionalSecondExpiryParses() {
        let headers = licenseUpdaterHeaders(
            accessToken: StoredAccessToken(token: "tok", expiresAt: "2099-01-01T00:00:00.000Z"),
            legacyKey: nil, machine: nil, now: now)

        #expect(headers == ["Authorization": "Bearer tok"])
    }

    @Test func expiredTokenFallsBackToLegacyHeaders() {
        let headers = licenseUpdaterHeaders(
            accessToken: StoredAccessToken(token: "tok", expiresAt: iso(offset: -600)),
            legacyKey: "EDITH-ABCD", machine: "hardware-1", now: now)

        #expect(headers == ["x-edith-license": "EDITH-ABCD", "x-edith-machine": "hardware-1"])
    }

    @Test func missingCredentialsYieldNoHeaders() {
        #expect(
            licenseUpdaterHeaders(accessToken: nil, legacyKey: nil, machine: nil, now: now)
                == [:])
    }

    @Test func expiredTokenWithRefreshCredentialIsStale() {
        #expect(
            licenseUpdaterTokenIsStale(
                accessToken: StoredAccessToken(token: "tok", expiresAt: iso(offset: -600)),
                hasRefreshCredential: true, now: now))
    }

    @Test func missingTokenWithRefreshCredentialIsStale() {
        #expect(licenseUpdaterTokenIsStale(accessToken: nil, hasRefreshCredential: true, now: now))
    }

    @Test func freshTokenIsNotStale() {
        #expect(
            !licenseUpdaterTokenIsStale(
                accessToken: StoredAccessToken(token: "tok", expiresAt: iso(offset: 600)),
                hasRefreshCredential: true, now: now))
    }

    @Test func withoutRefreshCredentialTokenIsNeverStale() {
        #expect(
            !licenseUpdaterTokenIsStale(accessToken: nil, hasRefreshCredential: false, now: now))
    }
}

@Suite struct LicenseV2SessionTests {
    private let baseURL = URL(string: "https://license.test/api/v1")!
    private static let challengeBody =
        #"{"challengeId":"ch-1","nonce":"n-1","expiresAt":"2026-07-19T00:05:00Z"}"#
    private static let successBody = """
        {"ok":true,"planId":"personal_3","machinesUsed":1,"maxMachines":3,
        "entitlement":"signed-entitlement","refreshCredential":"edithrc_abc",
        "accessToken":"token.sig","accessTokenExpiresAt":"2099-01-01T00:00:00.000Z"}
        """

    private func makeSession(
        transport: SequencedTransport, store: InMemoryLicenseCredentialStore,
        legacy: InMemoryV1KeyStore
    ) -> LicenseV2Session {
        LicenseV2Session(
            client: LicenseClient(transport: transport, baseURL: baseURL),
            credentialStore: store,
            deviceKeyStore: DeviceKeyStore(store: store, secureEnclaveAvailable: false),
            legacyStore: legacy,
            machineIdentifier: { "hardware-1" },
            appVersion: "9.9.9")
    }

    @Test func activationRequestsChallengeThenSignsIt() async throws {
        let transport = SequencedTransport(responses: [
            (200, Self.challengeBody), (200, Self.successBody),
        ])
        let store = InMemoryLicenseCredentialStore()
        let session = makeSession(
            transport: transport, store: store, legacy: InMemoryV1KeyStore())

        let response = try await session.activate(
            licenseKey: "EDITH-ABCD-1234-EFGH-5678", deviceName: "Test Mac")

        #expect(response.planId == "personal_3")
        #expect(transport.requests.count == 2)
        #expect(
            transport.requests[0].url?.absoluteString
                == "https://license.test/api/v2/activation/challenge")
        #expect(
            transport.requests[1].url?.absoluteString == "https://license.test/api/v2/activation")
        let payload = try body(of: transport.requests[1])
        #expect(payload["deviceName"] as? String == "Test Mac")
        #expect(payload["appVersion"] as? String == "9.9.9")
        #expect(payload["hostname"] == nil)
        try expectValidSignature(payload: payload, purpose: "activate")
    }

    @Test func activationStoresCredentialsAndTrustedTime() async throws {
        let transport = SequencedTransport(responses: [
            (200, Self.challengeBody), (200, Self.successBody),
        ])
        let store = InMemoryLicenseCredentialStore()
        let session = makeSession(
            transport: transport, store: store, legacy: InMemoryV1KeyStore())

        try await session.activate(licenseKey: "EDITH-ABCD-1234-EFGH-5678", deviceName: nil)

        #expect(try store.read(.entitlement) == "signed-entitlement")
        #expect(try store.read(.refreshCredential) == "edithrc_abc")
        let token = try #require(StoredAccessToken.load(from: store))
        #expect(token.freshToken() == "token.sig")
        #expect(TrustedTime.load(from: store) != nil)
    }

    @Test func migrationStoresV2AndRemovesV1OnSuccess() async throws {
        let transport = SequencedTransport(responses: [
            (200, Self.challengeBody), (200, Self.successBody),
        ])
        let store = InMemoryLicenseCredentialStore()
        let legacy = InMemoryV1KeyStore(key: "EDITH-ABCD-1234-EFGH-5678", receipt: "receipt-1")
        let session = makeSession(transport: transport, store: store, legacy: legacy)

        try await session.migrateFromV1()

        #expect(try store.read(.entitlement) == "signed-entitlement")
        #expect(try legacy.readKey() == nil)
        #expect(try legacy.readReceipt() == nil)
        let payload = try body(of: transport.requests[1])
        #expect(
            transport.requests[1].url?.absoluteString
                == "https://license.test/api/v2/devices/migrate")
        #expect(payload["hardwareUuid"] as? String == "hardware-1")
        try expectValidSignature(payload: payload, purpose: "migrate")
    }

    @Test func migrationKeepsV1OnFailure() async throws {
        let transport = SequencedTransport(responses: [
            (200, Self.challengeBody), (500, "{}"),
        ])
        let store = InMemoryLicenseCredentialStore()
        let legacy = InMemoryV1KeyStore(key: "EDITH-ABCD-1234-EFGH-5678", receipt: "receipt-1")
        let session = makeSession(transport: transport, store: store, legacy: legacy)

        await #expect(throws: LicenseClientError.server(statusCode: 500)) {
            try await session.migrateFromV1()
        }

        #expect(try store.read(.entitlement) == nil)
        #expect(try legacy.readKey() == "EDITH-ABCD-1234-EFGH-5678")
        #expect(try legacy.readReceipt() == "receipt-1")
    }

    @Test func deactivationClearsLocalStateOnlyAfterServerSuccess() async throws {
        let transport = SequencedTransport(responses: [
            (200, Self.challengeBody), (200, #"{"ok":true}"#),
        ])
        let store = try storeWithV2Credentials()
        let identity = try DeviceIdentity(
            credentialStore: store,
            keyStore: DeviceKeyStore(store: store, secureEnclaveAvailable: false))
        let session = makeSession(
            transport: transport, store: store, legacy: InMemoryV1KeyStore())

        try await session.deactivate()

        #expect(try store.read(.entitlement) == nil)
        #expect(try store.read(.refreshCredential) == nil)
        #expect(try store.read(.accessToken) == nil)
        #expect(try store.read(.trustedTime) == nil)
        #expect(try store.read(.deviceId) == nil)
        #expect(try store.read(.deviceKey) == nil)
        let challengePayload = try body(of: transport.requests[0])
        #expect(challengePayload["purpose"] as? String == "deactivate")
        #expect(challengePayload["refreshCredential"] as? String == "edithrc_abc")
        try expectValidSignature(
            payload: body(of: transport.requests[1]), purpose: "deactivate",
            publicKeyBase64URL: identity.publicKeySPKIBase64URL)
    }

    @Test func deactivationWithoutCredentialClearsLocalStateWithoutServerCall() async throws {
        let transport = SequencedTransport(responses: [])
        let store = try storeWithV2Credentials()
        try store.delete(.refreshCredential)
        let session = makeSession(
            transport: transport, store: store, legacy: InMemoryV1KeyStore())

        try await session.deactivate()

        #expect(transport.requests.isEmpty)
        #expect(try store.read(.entitlement) == nil)
        #expect(try store.read(.accessToken) == nil)
        #expect(try store.read(.trustedTime) == nil)
        #expect(try store.read(.deviceId) == nil)
        #expect(try store.read(.deviceKey) == nil)
    }

    @Test func deactivationFailureLeavesLocalStateUntouched() async throws {
        let transport = SequencedTransport(responses: [
            (200, Self.challengeBody), (500, "{}"),
        ])
        let store = try storeWithV2Credentials()
        let session = makeSession(
            transport: transport, store: store, legacy: InMemoryV1KeyStore())

        await #expect(throws: LicenseClientError.server(statusCode: 500)) {
            try await session.deactivate()
        }

        #expect(try store.read(.entitlement) == "signed-entitlement")
        #expect(try store.read(.refreshCredential) == "edithrc_abc")
        #expect(try store.read(.accessToken) != nil)
        #expect(try store.read(.trustedTime) != nil)
    }

    @Test func refreshRotatesStoredCredentials() async throws {
        let transport = SequencedTransport(responses: [
            (200, #"{"challengeId":"ch-9","nonce":"n-9","expiresAt":"2026-07-19T00:05:00Z"}"#),
            (
                200,
                """
                {"ok":true,"entitlement":"signed-entitlement-2",
                "refreshCredential":"edithrc_def","accessToken":"token2.sig",
                "accessTokenExpiresAt":"2099-01-01T00:00:00.000Z"}
                """
            ),
        ])
        let store = try storeWithV2Credentials()
        let session = makeSession(
            transport: transport, store: store, legacy: InMemoryV1KeyStore())

        try await session.refresh()

        #expect(try store.read(.entitlement) == "signed-entitlement-2")
        #expect(try store.read(.refreshCredential) == "edithrc_def")
    }

    @Test func refreshWithoutCredentialThrowsMissingCredentials() async throws {
        let session = makeSession(
            transport: SequencedTransport(responses: []),
            store: InMemoryLicenseCredentialStore(), legacy: InMemoryV1KeyStore())

        await #expect(throws: LicenseV2SessionError.missingCredentials) {
            try await session.refresh()
        }
    }

    private func storeWithV2Credentials() throws -> InMemoryLicenseCredentialStore {
        let store = InMemoryLicenseCredentialStore()
        try store.write("signed-entitlement", item: .entitlement)
        try store.write("edithrc_abc", item: .refreshCredential)
        try StoredAccessToken(token: "token.sig", expiresAt: "2099-01-01T00:00:00.000Z")
            .save(to: store)
        try TrustedTime.record(serverTime: Date()).save(to: store)
        _ = try DeviceIdentity(
            credentialStore: store,
            keyStore: DeviceKeyStore(store: store, secureEnclaveAvailable: false))
        return store
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectValidSignature(payload: [String: Any], purpose: String) throws {
        let publicKey = try #require(payload["devicePublicKey"] as? String)
        try expectValidSignature(payload: payload, purpose: purpose, publicKeyBase64URL: publicKey)
    }

    private func expectValidSignature(
        payload: [String: Any], purpose: String, publicKeyBase64URL: String
    ) throws {
        let spki = try #require(Base64URL.decode(publicKeyBase64URL))
        let key = try P256.Signing.PublicKey(derRepresentation: spki)
        let signature = try #require(payload["signature"] as? String)
        let der = try #require(Base64URL.decode(signature))
        let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: der)
        let challengeId = try #require(payload["challengeId"] as? String)
        let message = DeviceIdentity.challengeMessage(
            purpose: purpose, challengeId: challengeId, nonce: "n-1")
        #expect(key.isValidSignature(ecdsa, for: message))
    }
}

private final class SequencedTransport: LicenseTransport {
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Int, String)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw LicenseClientError.invalidResponse }
        let (statusCode, body) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private final class InMemoryV1KeyStore: LicenseKeyStoring {
    private var key: String?
    private var receipt: String?

    init(key: String? = nil, receipt: String? = nil) {
        self.key = key
        self.receipt = receipt
    }

    func readKey() throws -> String? {
        key
    }

    func writeKey(_ key: String) throws {
        self.key = key
    }

    func deleteKey() throws {
        key = nil
    }

    func readReceipt() throws -> String? {
        receipt
    }

    func writeReceipt(_ receipt: String) throws {
        self.receipt = receipt
    }

    func deleteReceipt() throws {
        receipt = nil
    }
}
