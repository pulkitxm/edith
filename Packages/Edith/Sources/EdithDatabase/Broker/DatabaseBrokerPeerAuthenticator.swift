import Darwin
import Foundation
import Security

enum DatabaseBrokerPeerAuthenticationError: Error, Equatable, Sendable {
    case invalidSocketDescriptor
    case peerUserIdentifierUnavailable
    case peerUserIdentifierMismatch(expected: uid_t, actual: uid_t)
    case peerAuditTokenUnavailable
    case malformedPeerAuditToken
    case peerCodeUnavailable
    case peerStaticCodeUnavailable
    case currentCodeUnavailable
    case currentStaticCodeUnavailable
    case currentDesignatedRequirementUnavailable
    case currentCodeInvalid
    case peerCodeInvalid
    case currentUniqueIdentifierUnavailable
    case peerUniqueIdentifierUnavailable
    case uniqueIdentifierMismatch
}

protocol DatabaseBrokerPeerAuthenticationSystem: Sendable {
    associatedtype Code: Sendable
    associatedtype StaticCode: Sendable
    associatedtype Requirement: Sendable

    func effectiveUserIdentifier() -> uid_t
    func peerUserIdentifier(socketDescriptor: Int32) throws -> uid_t
    func peerAuditToken(socketDescriptor: Int32) throws -> Data
    func peerCode(auditToken: Data) throws -> Code
    func currentCode() throws -> Code
    func staticCode(for code: Code) throws -> StaticCode
    func designatedRequirement(for code: StaticCode) throws -> Requirement
    func validate(code: Code, requirement: Requirement) throws
    func uniqueIdentifier(for code: StaticCode) throws -> Data
}

struct DatabaseBrokerPeerAuthenticator: Sendable {
    private let authenticatePeerImplementation: @Sendable (Int32) throws -> Void

    init() throws {
        try self.init(system: MacOSDatabaseBrokerPeerAuthenticationSystem())
    }

    init<System: DatabaseBrokerPeerAuthenticationSystem>(system: System) throws {
        let algorithm = DatabaseBrokerPeerAuthenticationAlgorithm(system: system)
        let currentIdentity = try algorithm.currentIdentity()
        authenticatePeerImplementation = { socketDescriptor in
            try algorithm.authenticatePeer(
                socketDescriptor: socketDescriptor,
                currentIdentity: currentIdentity)
        }
    }

    func authenticatePeer(socketDescriptor: Int32) throws {
        try authenticatePeerImplementation(socketDescriptor)
    }
}

private struct DatabaseBrokerCurrentCodeIdentity<Requirement: Sendable>: Sendable {
    let designatedRequirement: Requirement
    let uniqueIdentifier: Data
}

private struct DatabaseBrokerPeerAuthenticationAlgorithm<
    System: DatabaseBrokerPeerAuthenticationSystem
>: Sendable {
    let system: System

    func currentIdentity() throws -> DatabaseBrokerCurrentCodeIdentity<System.Requirement> {
        let currentCode: System.Code
        do {
            currentCode = try system.currentCode()
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.currentCodeUnavailable
        }

        let currentStaticCode: System.StaticCode
        do {
            currentStaticCode = try system.staticCode(for: currentCode)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.currentStaticCodeUnavailable
        }

        let designatedRequirement: System.Requirement
        do {
            designatedRequirement = try system.designatedRequirement(for: currentStaticCode)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.currentDesignatedRequirementUnavailable
        }

        do {
            try system.validate(code: currentCode, requirement: designatedRequirement)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.currentCodeInvalid
        }

        let uniqueIdentifier: Data
        do {
            uniqueIdentifier = try system.uniqueIdentifier(for: currentStaticCode)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.currentUniqueIdentifierUnavailable
        }
        guard !uniqueIdentifier.isEmpty else {
            throw DatabaseBrokerPeerAuthenticationError.currentUniqueIdentifierUnavailable
        }

        return DatabaseBrokerCurrentCodeIdentity(
            designatedRequirement: designatedRequirement,
            uniqueIdentifier: uniqueIdentifier)
    }

    func authenticatePeer(
        socketDescriptor: Int32,
        currentIdentity: DatabaseBrokerCurrentCodeIdentity<System.Requirement>
    ) throws {
        guard socketDescriptor >= 0 else {
            throw DatabaseBrokerPeerAuthenticationError.invalidSocketDescriptor
        }

        let expectedUserIdentifier = system.effectiveUserIdentifier()
        let peerUserIdentifier: uid_t
        do {
            peerUserIdentifier = try system.peerUserIdentifier(
                socketDescriptor: socketDescriptor)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.peerUserIdentifierUnavailable
        }
        guard peerUserIdentifier == expectedUserIdentifier else {
            throw DatabaseBrokerPeerAuthenticationError.peerUserIdentifierMismatch(
                expected: expectedUserIdentifier,
                actual: peerUserIdentifier)
        }

        let auditToken: Data
        do {
            auditToken = try system.peerAuditToken(socketDescriptor: socketDescriptor)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.peerAuditTokenUnavailable
        }
        guard auditToken.count == MemoryLayout<audit_token_t>.size else {
            throw DatabaseBrokerPeerAuthenticationError.malformedPeerAuditToken
        }

        let peerCode: System.Code
        do {
            peerCode = try system.peerCode(auditToken: auditToken)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.peerCodeUnavailable
        }

        let peerStaticCode: System.StaticCode
        do {
            peerStaticCode = try system.staticCode(for: peerCode)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.peerStaticCodeUnavailable
        }

        do {
            try system.validate(
                code: peerCode,
                requirement: currentIdentity.designatedRequirement)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.peerCodeInvalid
        }

        let peerUniqueIdentifier: Data
        do {
            peerUniqueIdentifier = try system.uniqueIdentifier(for: peerStaticCode)
        } catch {
            throw DatabaseBrokerPeerAuthenticationError.peerUniqueIdentifierUnavailable
        }
        guard !peerUniqueIdentifier.isEmpty else {
            throw DatabaseBrokerPeerAuthenticationError.peerUniqueIdentifierUnavailable
        }
        guard peerUniqueIdentifier == currentIdentity.uniqueIdentifier else {
            throw DatabaseBrokerPeerAuthenticationError.uniqueIdentifierMismatch
        }
    }
}

private enum MacOSDatabaseBrokerPeerAuthenticationSystemError: Error, Sendable {
    case systemCallFailed
}

private struct MacOSDatabaseBrokerCode: @unchecked Sendable {
    let value: SecCode
}

private struct MacOSDatabaseBrokerStaticCode: @unchecked Sendable {
    let value: SecStaticCode
}

private struct MacOSDatabaseBrokerCodeRequirement: @unchecked Sendable {
    let value: SecRequirement
}

private struct MacOSDatabaseBrokerPeerAuthenticationSystem:
    DatabaseBrokerPeerAuthenticationSystem
{
    private static let defaultFlags = SecCSFlags()
    private static let offlineValidationFlags = SecCSFlags.noNetworkAccess
    private static let signingInformationFlags = SecCSFlags(
        rawValue: kSecCSSigningInformation)

    func effectiveUserIdentifier() -> uid_t {
        geteuid()
    }

    func peerUserIdentifier(socketDescriptor: Int32) throws -> uid_t {
        var userIdentifier = uid_t()
        var groupIdentifier = gid_t()
        guard getpeereid(socketDescriptor, &userIdentifier, &groupIdentifier) == 0 else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return userIdentifier
    }

    func peerAuditToken(socketDescriptor: Int32) throws -> Data {
        var auditToken = audit_token_t()
        var auditTokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &auditToken) { auditTokenPointer in
            getsockopt(
                socketDescriptor,
                SOL_LOCAL,
                LOCAL_PEERTOKEN,
                auditTokenPointer,
                &auditTokenLength)
        }
        guard
            result == 0,
            auditTokenLength == socklen_t(MemoryLayout<audit_token_t>.size)
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return withUnsafeBytes(of: &auditToken) { Data($0) }
    }

    func peerCode(auditToken: Data) throws -> MacOSDatabaseBrokerCode {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(
                nil,
                attributes,
                Self.defaultFlags,
                &code) == errSecSuccess,
            let code
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerCode(value: code)
    }

    func currentCode() throws -> MacOSDatabaseBrokerCode {
        var code: SecCode?
        guard
            SecCodeCopySelf(Self.defaultFlags, &code) == errSecSuccess,
            let code
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerCode(value: code)
    }

    func staticCode(
        for code: MacOSDatabaseBrokerCode
    ) throws -> MacOSDatabaseBrokerStaticCode {
        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(
                code.value,
                Self.defaultFlags,
                &staticCode) == errSecSuccess,
            let staticCode
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerStaticCode(value: staticCode)
    }

    func designatedRequirement(
        for code: MacOSDatabaseBrokerStaticCode
    ) throws -> MacOSDatabaseBrokerCodeRequirement {
        var requirement: SecRequirement?
        guard
            SecCodeCopyDesignatedRequirement(
                code.value,
                Self.defaultFlags,
                &requirement) == errSecSuccess,
            let requirement
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return MacOSDatabaseBrokerCodeRequirement(value: requirement)
    }

    func validate(
        code: MacOSDatabaseBrokerCode,
        requirement: MacOSDatabaseBrokerCodeRequirement
    ) throws {
        guard
            SecCodeCheckValidity(
                code.value,
                Self.offlineValidationFlags,
                requirement.value) == errSecSuccess
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
    }

    func uniqueIdentifier(for code: MacOSDatabaseBrokerStaticCode) throws -> Data {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code.value,
                Self.signingInformationFlags,
                &information) == errSecSuccess,
            let signingInformation = information as? [String: Any],
            let uniqueIdentifier = signingInformation[kSecCodeInfoUnique as String] as? Data,
            !uniqueIdentifier.isEmpty
        else {
            throw MacOSDatabaseBrokerPeerAuthenticationSystemError.systemCallFailed
        }
        return uniqueIdentifier
    }
}
