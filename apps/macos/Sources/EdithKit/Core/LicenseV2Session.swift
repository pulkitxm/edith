import Foundation

public enum LicenseLaunchDecision: Equatable {
    case start
    case startAndMigrate
    case gate
}

extension LicenseRiskState {
    public var launchDecision: LicenseLaunchDecision {
        switch self {
        case .valid, .graceActive:
            return .start
        case .legacyV1:
            return .startAndMigrate
        case .noLicense, .recovery, .revoked:
            return .gate
        }
    }
}

extension LicenseCoordinator {
    public static func currentRiskState(
        credentialStore: any LicenseCredentialStoring = FileLicenseCredentialStore(),
        now: Date = Date()
    ) -> LicenseRiskState {
        let coordinator = LicenseCoordinator(
            store: credentialStore, legacyValidation: legacyReceiptValidation())
        guard
            let identity = try? DeviceIdentity(
                credentialStore: credentialStore,
                keyStore: DeviceKeyStore(store: credentialStore))
        else {
            return coordinator.riskState(deviceId: "", deviceKeyThumbprint: "", now: now)
        }
        return coordinator.riskState(
            deviceId: identity.deviceId, deviceKeyThumbprint: identity.thumbprint, now: now)
    }
}

extension LicenseEntitlement {
    public static func decodePayload(_ entitlement: String) -> LicenseEntitlement? {
        let components = entitlement.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = components.first,
            let payload = Base64URL.decode(String(first))
        else {
            return nil
        }
        return try? JSONDecoder().decode(LicenseEntitlement.self, from: payload)
    }
}

public struct StoredAccessToken: Codable, Equatable, Sendable {
    public let token: String
    public let expiresAt: String

    public init(token: String, expiresAt: String) {
        self.token = token
        self.expiresAt = expiresAt
    }

    public func freshToken(now: Date = Date()) -> String? {
        guard let expiry = Self.parseDate(expiresAt), expiry > now else { return nil }
        return token
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    public static func load(from store: any LicenseCredentialStoring) -> StoredAccessToken? {
        guard let raw = ((try? store.read(.accessToken)) ?? nil) else { return nil }
        return try? JSONDecoder().decode(StoredAccessToken.self, from: Data(raw.utf8))
    }

    public func save(to store: any LicenseCredentialStoring) throws {
        let data = try JSONEncoder().encode(self)
        try store.write(String(decoding: data, as: UTF8.self), item: .accessToken)
    }
}

public func licenseUpdaterHeaders(
    accessToken: StoredAccessToken?, legacyKey: String?, machine: String?, now: Date = Date()
) -> [String: String] {
    if let token = accessToken?.freshToken(now: now) {
        return ["Authorization": "Bearer \(token)"]
    }
    if let legacyKey, let machine {
        return ["x-edith-license": legacyKey, "x-edith-machine": machine]
    }
    return [:]
}

public enum LicenseV2SessionError: Error, Equatable {
    case missingCredentials
}

public struct LicenseV2Session {
    private let client: LicenseClient
    private let credentialStore: any LicenseCredentialStoring
    private let deviceKeyStore: any DeviceKeyStoring
    private let legacyStore: any LicenseKeyStoring
    private let machineIdentifier: () -> String?
    private let appVersion: String

    public init(
        client: LicenseClient = LicenseClient(),
        credentialStore: any LicenseCredentialStoring = FileLicenseCredentialStore(),
        deviceKeyStore: (any DeviceKeyStoring)? = nil,
        legacyStore: any LicenseKeyStoring = FileLicenseKeyStore(),
        machineIdentifier: @escaping () -> String? = hardwareUUID,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.deviceKeyStore = deviceKeyStore ?? DeviceKeyStore(store: credentialStore)
        self.legacyStore = legacyStore
        self.machineIdentifier = machineIdentifier
        self.appVersion = appVersion
    }

    @discardableResult
    public func activate(licenseKey: String, deviceName: String?) async throws
        -> LicenseV2ActivationResponse
    {
        let identity = try identity()
        let challenge = try await client.activationChallenge(
            licenseKey: licenseKey, deviceId: identity.deviceId,
            devicePublicKey: identity.publicKeySPKIBase64URL)
        let response = try await client.activateV2(
            licenseKey: licenseKey, challengeId: challenge.challengeId, nonce: challenge.nonce,
            deviceId: identity.deviceId, devicePublicKey: identity.publicKeySPKIBase64URL,
            signature: try signature(identity, purpose: "activate", challenge: challenge),
            appVersion: appVersion, deviceName: deviceName)
        try store(
            entitlement: response.entitlement, refreshCredential: response.refreshCredential,
            accessToken: response.accessToken,
            accessTokenExpiresAt: response.accessTokenExpiresAt)
        return response
    }

    @discardableResult
    public func migrateFromV1(deviceName: String? = nil) async throws
        -> LicenseV2ActivationResponse
    {
        guard let licenseKey = ((try? legacyStore.readKey()) ?? nil),
            let hardwareUuid = machineIdentifier()
        else {
            throw LicenseV2SessionError.missingCredentials
        }
        let identity = try identity()
        let challenge = try await client.activationChallenge(
            licenseKey: licenseKey, deviceId: identity.deviceId,
            devicePublicKey: identity.publicKeySPKIBase64URL, purpose: "migrate")
        let response = try await client.migrateV2(
            licenseKey: licenseKey, hardwareUuid: hardwareUuid, deviceId: identity.deviceId,
            devicePublicKey: identity.publicKeySPKIBase64URL,
            challengeId: challenge.challengeId, nonce: challenge.nonce,
            signature: try signature(identity, purpose: "migrate", challenge: challenge),
            appVersion: appVersion, deviceName: deviceName)
        try store(
            entitlement: response.entitlement, refreshCredential: response.refreshCredential,
            accessToken: response.accessToken,
            accessTokenExpiresAt: response.accessTokenExpiresAt)
        try? legacyStore.deleteKey()
        try? legacyStore.deleteReceipt()
        return response
    }

    public func refresh() async throws {
        guard let credential = ((try? credentialStore.read(.refreshCredential)) ?? nil) else {
            throw LicenseV2SessionError.missingCredentials
        }
        let identity = try identity()
        let challenge = try await client.refreshChallenge(
            deviceId: identity.deviceId, refreshCredential: credential)
        let response = try await client.refreshV2(
            deviceId: identity.deviceId, challengeId: challenge.challengeId,
            nonce: challenge.nonce,
            signature: try signature(identity, purpose: "refresh", challenge: challenge),
            appVersion: appVersion)
        try store(
            entitlement: response.entitlement, refreshCredential: response.refreshCredential,
            accessToken: response.accessToken,
            accessTokenExpiresAt: response.accessTokenExpiresAt)
    }

    public func deactivate() async throws {
        guard let credential = ((try? credentialStore.read(.refreshCredential)) ?? nil) else {
            throw LicenseV2SessionError.missingCredentials
        }
        let identity = try identity()
        let challenge = try await client.refreshChallenge(
            deviceId: identity.deviceId, refreshCredential: credential, purpose: "deactivate")
        _ = try await client.deactivateV2(
            deviceId: identity.deviceId, challengeId: challenge.challengeId,
            nonce: challenge.nonce,
            signature: try signature(identity, purpose: "deactivate", challenge: challenge))
        for item in [
            LicenseCredentialItem.entitlement, .refreshCredential, .accessToken, .trustedTime,
            .deviceKey, .deviceId,
        ] {
            try? credentialStore.delete(item)
        }
    }

    private func identity() throws -> DeviceIdentity {
        try DeviceIdentity(credentialStore: credentialStore, keyStore: deviceKeyStore)
    }

    private func signature(
        _ identity: DeviceIdentity, purpose: String, challenge: LicenseChallengeResponse
    ) throws -> String {
        try identity.sign(
            message: DeviceIdentity.challengeMessage(
                purpose: purpose, challengeId: challenge.challengeId, nonce: challenge.nonce))
    }

    private func store(
        entitlement: String, refreshCredential: String, accessToken: String,
        accessTokenExpiresAt: String
    ) throws {
        try credentialStore.write(entitlement, item: .entitlement)
        try credentialStore.write(refreshCredential, item: .refreshCredential)
        try StoredAccessToken(token: accessToken, expiresAt: accessTokenExpiresAt)
            .save(to: credentialStore)
        try TrustedTime.record(serverTime: Date()).save(to: credentialStore)
    }
}
