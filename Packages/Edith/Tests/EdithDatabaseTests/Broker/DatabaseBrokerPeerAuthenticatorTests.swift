import Darwin
import Foundation
import Security
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerPeerAuthenticationSystemStubError: Error {
    case requestedFailure
}

private final class DatabaseBrokerPeerAuthenticationSystemStub: @unchecked Sendable,
    DatabaseBrokerPeerAuthenticationSystem
{
    enum Code: Hashable, Sendable {
        case current
        case peer
    }

    enum StaticCode: Hashable, Sendable {
        case current
        case peer
    }

    enum Requirement: Equatable, Sendable {
        case current
    }

    enum Failure: Equatable {
        case peerUserIdentifier
        case peerAuditToken
        case peerCode
        case peerStaticCode
        case currentCode
        case currentStaticCode
        case designatedRequirement
        case currentCodeValidation
        case peerCodeValidation
        case currentUniqueIdentifier
        case peerUniqueIdentifier
    }

    enum Call: Equatable {
        case effectiveUserIdentifier
        case peerUserIdentifier(Int32)
        case peerAuditToken(Int32)
        case peerCode(Data)
        case currentCode
        case staticCode(Code)
        case designatedRequirement(StaticCode)
        case validate(Code, Requirement)
        case uniqueIdentifier(StaticCode)
    }

    var expectedUserIdentifier = uid_t(501)
    var peerUserIdentifierValue = uid_t(501)
    var auditToken = Data(
        repeating: 0xA5,
        count: MemoryLayout<audit_token_t>.size)
    var uniqueIdentifiers: [StaticCode: Data] = [
        .current: Data([0x10, 0x20, 0x30]),
        .peer: Data([0x10, 0x20, 0x30]),
    ]
    var failure: Failure?
    var calls: [Call] = []

    func effectiveUserIdentifier() -> uid_t {
        calls.append(.effectiveUserIdentifier)
        return expectedUserIdentifier
    }

    func peerUserIdentifier(socketDescriptor: Int32) throws -> uid_t {
        calls.append(.peerUserIdentifier(socketDescriptor))
        try failIfRequested(.peerUserIdentifier)
        return peerUserIdentifierValue
    }

    func peerAuditToken(socketDescriptor: Int32) throws -> Data {
        calls.append(.peerAuditToken(socketDescriptor))
        try failIfRequested(.peerAuditToken)
        return auditToken
    }

    func peerCode(auditToken: Data) throws -> Code {
        calls.append(.peerCode(auditToken))
        try failIfRequested(.peerCode)
        return .peer
    }

    func currentCode() throws -> Code {
        calls.append(.currentCode)
        try failIfRequested(.currentCode)
        return .current
    }

    func staticCode(for code: Code) throws -> StaticCode {
        calls.append(.staticCode(code))
        switch code {
        case .current:
            try failIfRequested(.currentStaticCode)
            return .current
        case .peer:
            try failIfRequested(.peerStaticCode)
            return .peer
        }
    }

    func designatedRequirement(for code: StaticCode) throws -> Requirement {
        calls.append(.designatedRequirement(code))
        try failIfRequested(.designatedRequirement)
        return .current
    }

    func validate(code: Code, requirement: Requirement) throws {
        calls.append(.validate(code, requirement))
        switch code {
        case .current:
            try failIfRequested(.currentCodeValidation)
        case .peer:
            try failIfRequested(.peerCodeValidation)
        }
    }

    func uniqueIdentifier(for code: StaticCode) throws -> Data {
        calls.append(.uniqueIdentifier(code))
        switch code {
        case .current:
            try failIfRequested(.currentUniqueIdentifier)
        case .peer:
            try failIfRequested(.peerUniqueIdentifier)
        }
        guard let uniqueIdentifier = uniqueIdentifiers[code] else {
            throw DatabaseBrokerPeerAuthenticationSystemStubError.requestedFailure
        }
        return uniqueIdentifier
    }

    private func failIfRequested(_ requestedFailure: Failure) throws {
        if failure == requestedFailure {
            throw DatabaseBrokerPeerAuthenticationSystemStubError.requestedFailure
        }
    }
}

private enum DatabaseBrokerLivePeerAuthenticationSupport {
    static let isAvailable: Bool = {
        let defaultFlags = SecCSFlags()
        var dynamicCode: SecCode?
        guard
            SecCodeCopySelf(defaultFlags, &dynamicCode) == errSecSuccess,
            let dynamicCode
        else {
            return false
        }
        var staticCode: SecStaticCode?
        guard
            SecCodeCopyStaticCode(
                dynamicCode,
                defaultFlags,
                &staticCode) == errSecSuccess,
            let staticCode
        else {
            return false
        }
        var requirement: SecRequirement?
        guard
            SecCodeCopyDesignatedRequirement(
                staticCode,
                defaultFlags,
                &requirement) == errSecSuccess,
            let requirement,
            SecCodeCheckValidity(
                dynamicCode,
                SecCSFlags.noNetworkAccess,
                requirement) == errSecSuccess
        else {
            return false
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &information) == errSecSuccess,
            let signingInformation = information as? [String: Any],
            let uniqueIdentifier = signingInformation[kSecCodeInfoUnique as String] as? Data
        else {
            return false
        }
        return !uniqueIdentifier.isEmpty
    }()
}

@Suite struct DatabaseBrokerPeerAuthenticatorTests {
    @Test func cachesValidatedCurrentIdentityAndAuthenticatesEveryPeer() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)

        try authenticator.authenticatePeer(socketDescriptor: 41)
        try authenticator.authenticatePeer(socketDescriptor: 42)

        #expect(
            system.calls == [
                .currentCode,
                .staticCode(.current),
                .designatedRequirement(.current),
                .validate(.current, .current),
                .uniqueIdentifier(.current),
                .effectiveUserIdentifier,
                .peerUserIdentifier(41),
                .peerAuditToken(41),
                .peerCode(system.auditToken),
                .staticCode(.peer),
                .validate(.peer, .current),
                .uniqueIdentifier(.peer),
                .effectiveUserIdentifier,
                .peerUserIdentifier(42),
                .peerAuditToken(42),
                .peerCode(system.auditToken),
                .staticCode(.peer),
                .validate(.peer, .current),
                .uniqueIdentifier(.peer),
            ])
    }

    @Test func rejectsInvalidSocketDescriptorBeforeReadingPeerIdentity() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.calls.removeAll()

        #expect(throws: DatabaseBrokerPeerAuthenticationError.invalidSocketDescriptor) {
            try authenticator.authenticatePeer(socketDescriptor: -1)
        }
        #expect(system.calls.isEmpty)
    }

    @Test func rejectsUnavailablePeerUserIdentifier() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.calls.removeAll()
        system.failure = .peerUserIdentifier

        #expect(
            throws: DatabaseBrokerPeerAuthenticationError.peerUserIdentifierUnavailable
        ) {
            try authenticator.authenticatePeer(socketDescriptor: 7)
        }
        #expect(
            system.calls == [
                .effectiveUserIdentifier,
                .peerUserIdentifier(7),
            ])
    }

    @Test func rejectsDifferentPeerUserBeforeReadingAuditToken() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.calls.removeAll()
        system.expectedUserIdentifier = 501
        system.peerUserIdentifierValue = 502

        #expect(
            throws: DatabaseBrokerPeerAuthenticationError.peerUserIdentifierMismatch(
                expected: 501,
                actual: 502)
        ) {
            try authenticator.authenticatePeer(socketDescriptor: 8)
        }
        #expect(
            system.calls == [
                .effectiveUserIdentifier,
                .peerUserIdentifier(8),
            ])
    }

    @Test func rejectsUnavailableAuditToken() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.calls.removeAll()
        system.failure = .peerAuditToken

        #expect(throws: DatabaseBrokerPeerAuthenticationError.peerAuditTokenUnavailable) {
            try authenticator.authenticatePeer(socketDescriptor: 9)
        }
        #expect(
            system.calls == [
                .effectiveUserIdentifier,
                .peerUserIdentifier(9),
                .peerAuditToken(9),
            ])
    }

    @Test(arguments: [0, 31, 33])
    func rejectsMalformedAuditToken(length: Int) throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.calls.removeAll()
        system.auditToken = Data(repeating: 0, count: length)

        #expect(throws: DatabaseBrokerPeerAuthenticationError.malformedPeerAuditToken) {
            try authenticator.authenticatePeer(socketDescriptor: 10)
        }
        #expect(
            system.calls == [
                .effectiveUserIdentifier,
                .peerUserIdentifier(10),
                .peerAuditToken(10),
            ])
    }

    @Test func rejectsAuditTokenThatCannotResolveRunningCode() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.failure = .peerCode

        #expect(throws: DatabaseBrokerPeerAuthenticationError.peerCodeUnavailable) {
            try authenticator.authenticatePeer(socketDescriptor: 11)
        }
    }

    @Test func rejectsPeerWhoseStaticCodeCannotBeResolved() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.failure = .peerStaticCode

        #expect(throws: DatabaseBrokerPeerAuthenticationError.peerStaticCodeUnavailable) {
            try authenticator.authenticatePeer(socketDescriptor: 12)
        }
    }

    @Test func rejectsUnavailableCurrentCodeDuringInitialization() {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        system.failure = .currentCode

        #expect(throws: DatabaseBrokerPeerAuthenticationError.currentCodeUnavailable) {
            _ = try DatabaseBrokerPeerAuthenticator(system: system)
        }
    }

    @Test func rejectsCurrentCodeWithoutStaticCodeDuringInitialization() {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        system.failure = .currentStaticCode

        #expect(throws: DatabaseBrokerPeerAuthenticationError.currentStaticCodeUnavailable) {
            _ = try DatabaseBrokerPeerAuthenticator(system: system)
        }
    }

    @Test func rejectsUnavailableCurrentDesignatedRequirement() {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        system.failure = .designatedRequirement

        #expect(
            throws:
                DatabaseBrokerPeerAuthenticationError.currentDesignatedRequirementUnavailable
        ) {
            _ = try DatabaseBrokerPeerAuthenticator(system: system)
        }
    }

    @Test func rejectsCurrentCodeThatFailsOfflineValidation() {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        system.failure = .currentCodeValidation

        #expect(throws: DatabaseBrokerPeerAuthenticationError.currentCodeInvalid) {
            _ = try DatabaseBrokerPeerAuthenticator(system: system)
        }
        #expect(!system.calls.contains(.uniqueIdentifier(.current)))
    }

    @Test func rejectsPeerCodeThatFailsCurrentDesignatedRequirement() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.calls.removeAll()
        system.failure = .peerCodeValidation

        #expect(throws: DatabaseBrokerPeerAuthenticationError.peerCodeInvalid) {
            try authenticator.authenticatePeer(socketDescriptor: 15)
        }
        #expect(system.calls.contains(.validate(.peer, .current)))
        #expect(!system.calls.contains(.uniqueIdentifier(.peer)))
    }

    @Test func rejectsUnavailableCurrentUniqueIdentifierDuringInitialization() {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        system.failure = .currentUniqueIdentifier

        #expect(
            throws: DatabaseBrokerPeerAuthenticationError.currentUniqueIdentifierUnavailable
        ) {
            _ = try DatabaseBrokerPeerAuthenticator(system: system)
        }
    }

    @Test func rejectsEmptyCurrentUniqueIdentifierDuringInitialization() {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        system.uniqueIdentifiers[.current] = Data()

        #expect(
            throws: DatabaseBrokerPeerAuthenticationError.currentUniqueIdentifierUnavailable
        ) {
            _ = try DatabaseBrokerPeerAuthenticator(system: system)
        }
    }

    @Test func rejectsUnavailablePeerUniqueIdentifier() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.failure = .peerUniqueIdentifier

        #expect(
            throws: DatabaseBrokerPeerAuthenticationError.peerUniqueIdentifierUnavailable
        ) {
            try authenticator.authenticatePeer(socketDescriptor: 18)
        }
    }

    @Test func rejectsEmptyPeerUniqueIdentifier() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.uniqueIdentifiers[.peer] = Data()

        #expect(
            throws: DatabaseBrokerPeerAuthenticationError.peerUniqueIdentifierUnavailable
        ) {
            try authenticator.authenticatePeer(socketDescriptor: 19)
        }
    }

    @Test func rejectsPeerWithDifferentExactUniqueIdentifier() throws {
        let system = DatabaseBrokerPeerAuthenticationSystemStub()
        let authenticator = try DatabaseBrokerPeerAuthenticator(system: system)
        system.uniqueIdentifiers[.peer] = Data([0x10, 0x20, 0x31])

        #expect(throws: DatabaseBrokerPeerAuthenticationError.uniqueIdentifierMismatch) {
            try authenticator.authenticatePeer(socketDescriptor: 20)
        }
    }

    @Test(
        .enabled(
            if: DatabaseBrokerLivePeerAuthenticationSupport.isAvailable,
            "requires a signed macOS test process with a complete Security identity"))
    func mutuallyAuthenticatesCurrentProcessAcrossUnixSocketPair() throws {
        var socketDescriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &socketDescriptors) == 0)
        defer {
            _ = close(socketDescriptors[0])
            _ = close(socketDescriptors[1])
        }
        let authenticator = try DatabaseBrokerPeerAuthenticator()

        try authenticator.authenticatePeer(socketDescriptor: socketDescriptors[0])
        try authenticator.authenticatePeer(socketDescriptor: socketDescriptors[1])
    }
}
