import Foundation

public enum LicenseRiskState: Equatable {
    case noLicense
    case valid(LicenseEntitlement)
    case graceActive(remainingDays: Int, warn: Bool)
    case recovery
    case revoked
    case legacyV1(needsMigration: Bool)
}

public struct LicenseCoordinator {
    public static let defaultGraceDays = 30
    public static let warnWindowDays = 5

    private let store: any LicenseCredentialStoring
    private let verifier: EntitlementVerifier
    private let legacyValidation: () -> LicenseReceiptValidation?
    private let graceDays: Int

    public init(
        store: any LicenseCredentialStoring,
        verifier: EntitlementVerifier = EntitlementVerifier(),
        legacyValidation: @escaping () -> LicenseReceiptValidation? = { nil },
        graceDays: Int = LicenseCoordinator.defaultGraceDays
    ) {
        self.store = store
        self.verifier = verifier
        self.legacyValidation = legacyValidation
        self.graceDays = graceDays
    }

    public static func legacyReceiptValidation(
        keyStore: any LicenseKeyStoring = FileLicenseKeyStore(),
        verifier: LicenseReceiptVerifier = LicenseReceiptVerifier(),
        machineIdentifier: @escaping () -> String? = hardwareUUID
    ) -> () -> LicenseReceiptValidation? {
        {
            guard ((try? keyStore.readKey()) ?? nil) != nil,
                let receipt = ((try? keyStore.readReceipt()) ?? nil),
                let machine = machineIdentifier()
            else {
                return nil
            }
            return verifier.validation(receipt: receipt, expectedMachine: machine)
        }
    }

    public func riskState(deviceId: String, deviceKeyThumbprint: String, now: Date = Date())
        -> LicenseRiskState
    {
        guard let entitlement = ((try? store.read(.entitlement)) ?? nil), !entitlement.isEmpty
        else {
            return legacyState()
        }
        let assessment = TrustedTime.load(from: store)?.assess(now: now) ?? .plausible
        switch verifier.validation(
            entitlement: entitlement, expectedDeviceId: deviceId,
            expectedThumbprint: deviceKeyThumbprint, now: now)
        {
        case .valid(let payload):
            return assessment == .rollbackSuspected
                ? .graceActive(remainingDays: graceDays, warn: false)
                : .valid(payload)
        case .expired(let payload):
            return graceState(expiresAt: payload.expiresAt, now: now)
        case .notYetValid, .unknownKey:
            return .recovery
        case .invalid:
            return .revoked
        }
    }

    private func graceState(expiresAt: Int64, now: Date) -> LicenseRiskState {
        let elapsedDays = Int(floor((now.timeIntervalSince1970 - Double(expiresAt)) / 86_400))
        let remaining = graceDays - elapsedDays
        guard remaining > 0 else { return .recovery }
        return .graceActive(remainingDays: remaining, warn: remaining <= Self.warnWindowDays)
    }

    private func legacyState() -> LicenseRiskState {
        switch legacyValidation() {
        case .valid:
            return .legacyV1(needsMigration: true)
        default:
            return .noLicense
        }
    }
}
