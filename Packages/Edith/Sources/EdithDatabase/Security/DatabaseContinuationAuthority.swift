import CryptoKit
import Foundation

enum DatabaseContinuationAuthorityError: Error, Equatable, Sendable {
    case invalidSigningKeyBytes(Int)
    case invalidLifetimeSeconds(Int)
    case invalidRequest
    case malformedToken
    case unsupportedVersion(Int)
    case invalidAudience
    case invalidSignature
    case issuedInFuture
    case expired
    case lifetimeExceeded
    case contextMismatch
    case malformedPayload
    case payloadLimitExceeded(actual: Int, maximum: Int)
}

struct DatabaseContinuationAuthority: Sendable {
    static let tokenSchemaVersion = 1
    static let tokenAudience = "com.pulkitxm.edith.database-continuation"
    static let signingKeyByteRange = 32...64
    static let lifetimeSecondRange = 1...3_600
    static let defaultLifetimeSeconds = 300
    static let maximumClockSkewSeconds = 30
    static let maximumTokenBytes = DatabaseExecutionValidator.maximumContinuationTokenBytes
    static let maximumHeaderBytes = 4_096
    static let maximumEnvelopeBytes = 126_976
    static let maximumProtectedPayloadBytes = 90_000
    static let maximumCanonicalContextBytes = DatabaseExecutionValidator.maximumRequestBytes

    static let signingKeyReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "FE9DD39B-7D15-4EE2-A012-D6F64F7DC658")!,
        purpose: .continuationSigningKey)

    private let signingKey: SymmetricKey
    private let encryptionKey: SymmetricKey
    private let currentDate: @Sendable () -> Date

    init(
        signingKey: Data,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard Self.signingKeyByteRange.contains(signingKey.count) else {
            throw DatabaseContinuationAuthorityError.invalidSigningKeyBytes(signingKey.count)
        }
        let key = SymmetricKey(data: signingKey)
        self.signingKey = key
        encryptionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data(Self.tokenAudience.utf8),
            info: Data("payload-encryption".utf8),
            outputByteCount: 32)
        self.currentDate = currentDate
    }

    static func create(
        secretStore: any DatabaseSecretStore
    ) async throws -> DatabaseContinuationAuthority {
        var generator = SystemRandomNumberGenerator()
        let proposedKey = Data(
            (0..<signingKeyByteRange.lowerBound).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            })
        let signingKey = try await secretStore.storeIfAbsent(
            proposedKey,
            for: signingKeyReference)
        return try DatabaseContinuationAuthority(signingKey: signingKey)
    }

    func issue(
        _ continuation: DatabaseAdapterContinuation,
        for request: DatabaseBrowseRequest,
        lifetimeSeconds: Int = Self.defaultLifetimeSeconds
    ) throws -> DatabaseContinuationToken {
        try issue(
            continuation,
            binding: Self.binding(for: request),
            lifetimeSeconds: lifetimeSeconds)
    }

    func issue(
        _ continuation: DatabaseAdapterContinuation,
        for request: DatabaseQueryRequest,
        lifetimeSeconds: Int = Self.defaultLifetimeSeconds
    ) throws -> DatabaseContinuationToken {
        try issue(
            continuation,
            binding: Self.binding(for: request),
            lifetimeSeconds: lifetimeSeconds)
    }

    func open(
        _ token: DatabaseContinuationToken,
        for request: DatabaseBrowseRequest
    ) throws -> DatabaseAdapterContinuation {
        try open(token, binding: Self.binding(for: request))
    }

    func open(
        _ token: DatabaseContinuationToken,
        for request: DatabaseQueryRequest
    ) throws -> DatabaseAdapterContinuation {
        try open(token, binding: Self.binding(for: request))
    }

    private func issue(
        _ continuation: DatabaseAdapterContinuation,
        binding: DatabaseContinuationRequestBinding,
        lifetimeSeconds: Int
    ) throws -> DatabaseContinuationToken {
        guard Self.lifetimeSecondRange.contains(lifetimeSeconds) else {
            throw DatabaseContinuationAuthorityError.invalidLifetimeSeconds(lifetimeSeconds)
        }
        guard continuation.payload.count <= DatabaseAdapterBounds.maximumContinuationBytes else {
            throw DatabaseContinuationAuthorityError.payloadLimitExceeded(
                actual: continuation.payload.count,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        }
        let now = currentDate()
        try Self.validateFinite(now)
        let requestedExpiry = now.addingTimeInterval(TimeInterval(lifetimeSeconds))
        try Self.validateFinite(requestedExpiry)
        if let adapterExpiry = continuation.expiresAt {
            try Self.validateFinite(adapterExpiry)
            guard adapterExpiry > now else {
                throw DatabaseContinuationAuthorityError.expired
            }
        }
        let expiresAt = min(requestedExpiry, continuation.expiresAt ?? requestedExpiry)
        let context = try contextDigests(for: binding)
        let header = DatabaseContinuationTokenHeader(
            version: Self.tokenSchemaVersion,
            audience: Self.tokenAudience,
            identifier: UUID(),
            operation: binding.operation,
            context: context,
            mode: continuation.mode,
            issuedAt: DatabaseContinuationTimestamp(now),
            expiresAt: DatabaseContinuationTimestamp(expiresAt))
        let protectedPayload = DatabaseContinuationProtectedPayload(
            mode: continuation.mode,
            payload: continuation.payload,
            adapterExpiresAt: continuation.expiresAt.map(DatabaseContinuationTimestamp.init))
        let protectedData = try Self.encode(protectedPayload)
        guard protectedData.count <= Self.maximumProtectedPayloadBytes else {
            throw DatabaseContinuationAuthorityError.payloadLimitExceeded(
                actual: protectedData.count,
                maximum: Self.maximumProtectedPayloadBytes)
        }
        let authenticatedHeader = try Self.encode(header)
        let sealedPayload: Data
        do {
            sealedPayload = try ChaChaPoly.seal(
                protectedData,
                using: encryptionKey,
                authenticating: authenticatedHeader
            ).combined
        } catch {
            throw DatabaseContinuationAuthorityError.malformedPayload
        }
        let envelope = DatabaseContinuationSignedEnvelope(
            header: header,
            sealedPayload: sealedPayload)
        let envelopeData = try Self.encode(envelope)
        guard envelopeData.count <= Self.maximumEnvelopeBytes else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: Self.domainSeparated(envelopeData, domain: "token"),
                using: signingKey))
        let token = DatabaseContinuationToken(
            rawValue:
                "\(authenticatedHeader.databaseContinuationBase64URLString()).\(sealedPayload.databaseContinuationBase64URLString()).\(signature.databaseContinuationBase64URLString())"
        )
        guard token.rawValue.utf8.count <= Self.maximumTokenBytes else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        return token
    }

    private func open(
        _ token: DatabaseContinuationToken,
        binding: DatabaseContinuationRequestBinding
    ) throws -> DatabaseAdapterContinuation {
        let envelope = try authenticate(token)
        guard envelope.header.version == Self.tokenSchemaVersion else {
            throw DatabaseContinuationAuthorityError.unsupportedVersion(envelope.header.version)
        }
        guard envelope.header.audience == Self.tokenAudience else {
            throw DatabaseContinuationAuthorityError.invalidAudience
        }
        guard envelope.header.operation == binding.operation else {
            throw DatabaseContinuationAuthorityError.contextMismatch
        }
        let issuedAt = try Self.date(from: envelope.header.issuedAt)
        let expiresAt = try Self.date(from: envelope.header.expiresAt)
        let now = currentDate()
        try Self.validateFinite(now)
        guard issuedAt <= now.addingTimeInterval(TimeInterval(Self.maximumClockSkewSeconds)) else {
            throw DatabaseContinuationAuthorityError.issuedInFuture
        }
        guard expiresAt > now else {
            throw DatabaseContinuationAuthorityError.expired
        }
        let lifetime = expiresAt.timeIntervalSince(issuedAt)
        guard lifetime > 0,
            lifetime <= TimeInterval(Self.lifetimeSecondRange.upperBound)
        else {
            throw DatabaseContinuationAuthorityError.lifetimeExceeded
        }
        let expectedContext = try contextDigests(for: binding)
        guard Self.matches(envelope.header.context, expectedContext) else {
            throw DatabaseContinuationAuthorityError.contextMismatch
        }
        let protectedData: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.sealedPayload)
            protectedData = try ChaChaPoly.open(
                box,
                using: encryptionKey,
                authenticating: Self.encode(envelope.header))
        } catch {
            throw DatabaseContinuationAuthorityError.malformedPayload
        }
        guard protectedData.count <= Self.maximumProtectedPayloadBytes else {
            throw DatabaseContinuationAuthorityError.payloadLimitExceeded(
                actual: protectedData.count,
                maximum: Self.maximumProtectedPayloadBytes)
        }
        let protectedPayload: DatabaseContinuationProtectedPayload
        do {
            protectedPayload = try Self.decoder().decode(
                DatabaseContinuationProtectedPayload.self,
                from: protectedData)
            guard try Self.encode(protectedPayload) == protectedData else {
                throw DatabaseContinuationAuthorityError.malformedPayload
            }
        } catch let error as DatabaseContinuationAuthorityError {
            throw error
        } catch {
            throw DatabaseContinuationAuthorityError.malformedPayload
        }
        guard protectedPayload.payload.count <= DatabaseAdapterBounds.maximumContinuationBytes
        else {
            throw DatabaseContinuationAuthorityError.payloadLimitExceeded(
                actual: protectedPayload.payload.count,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        }
        guard protectedPayload.mode == envelope.header.mode else {
            throw DatabaseContinuationAuthorityError.malformedPayload
        }
        let adapterExpiresAt = try protectedPayload.adapterExpiresAt.map(Self.date(from:))
        if let adapterExpiresAt {
            guard adapterExpiresAt > issuedAt, expiresAt <= adapterExpiresAt else {
                throw DatabaseContinuationAuthorityError.lifetimeExceeded
            }
        }
        do {
            return try DatabaseAdapterContinuation(
                mode: envelope.header.mode,
                payload: protectedPayload.payload,
                expiresAt: adapterExpiresAt)
        } catch {
            throw DatabaseContinuationAuthorityError.payloadLimitExceeded(
                actual: protectedPayload.payload.count,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        }
    }

    private func authenticate(
        _ token: DatabaseContinuationToken
    ) throws -> DatabaseContinuationSignedEnvelope {
        guard !token.rawValue.isEmpty,
            token.rawValue.utf8.count <= Self.maximumTokenBytes
        else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        let parts = token.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let headerData = Data(databaseContinuationBase64URL: String(parts[0])),
            let sealedPayload = Data(databaseContinuationBase64URL: String(parts[1])),
            let signature = Data(databaseContinuationBase64URL: String(parts[2])),
            headerData.databaseContinuationBase64URLString() == parts[0],
            sealedPayload.databaseContinuationBase64URLString() == parts[1],
            signature.databaseContinuationBase64URLString() == parts[2],
            headerData.count <= Self.maximumHeaderBytes,
            sealedPayload.count >= 28,
            sealedPayload.count <= Self.maximumProtectedPayloadBytes + 28,
            signature.count == SHA256.byteCount
        else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        do {
            let header = try Self.decoder().decode(
                DatabaseContinuationTokenHeader.self,
                from: headerData)
            guard try Self.encode(header) == headerData else {
                throw DatabaseContinuationAuthorityError.malformedToken
            }
            let envelope = DatabaseContinuationSignedEnvelope(
                header: header,
                sealedPayload: sealedPayload)
            let envelopeData = try Self.encode(envelope)
            guard envelopeData.count <= Self.maximumEnvelopeBytes,
                header.context.allDigestsHaveExpectedLength
            else {
                throw DatabaseContinuationAuthorityError.malformedToken
            }
            guard
                HMAC<SHA256>.isValidAuthenticationCode(
                    signature,
                    authenticating: Self.domainSeparated(envelopeData, domain: "token"),
                    using: signingKey)
            else {
                throw DatabaseContinuationAuthorityError.invalidSignature
            }
            return envelope
        } catch let error as DatabaseContinuationAuthorityError {
            throw error
        } catch {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
    }

    private func contextDigests(
        for binding: DatabaseContinuationRequestBinding
    ) throws -> DatabaseContinuationContextDigests {
        let connection = try keyedDigest(binding.connectionID, domain: "connection")
        let target = try keyedDigest(binding.target, domain: "target")
        let filter = try keyedDigest(
            DatabaseContinuationOptionalFilter(value: binding.page.filter),
            domain: "filter")
        let sorts = try keyedDigest(binding.page.sorts, domain: "sorts")
        let projection = try keyedDigest(
            DatabaseContinuationOptionalProjection(value: binding.page.projection),
            domain: "projection")
        let consistency = try keyedDigest(binding.page.consistency, domain: "consistency")
        let query = try binding.query.map { try keyedDigest($0, domain: "query") }
        let request = try keyedDigest(
            DatabaseContinuationAggregateBinding(
                version: binding.version,
                operation: binding.operation,
                connectionID: binding.connectionID,
                target: binding.target,
                pageSize: binding.page.pageSize,
                connectionDigest: connection,
                targetDigest: target,
                filterDigest: filter,
                sortsDigest: sorts,
                projectionDigest: projection,
                consistencyDigest: consistency,
                queryDigest: query),
            domain: "request")
        return DatabaseContinuationContextDigests(
            request: request,
            connection: connection,
            target: target,
            filter: filter,
            sorts: sorts,
            projection: projection,
            consistency: consistency,
            query: query)
    }

    private func keyedDigest<Value: Encodable>(
        _ value: Value,
        domain: String
    ) throws -> Data {
        let data = try Self.encode(value)
        guard data.count <= Self.maximumCanonicalContextBytes else {
            throw DatabaseContinuationAuthorityError.invalidRequest
        }
        return Data(
            HMAC<SHA256>.authenticationCode(
                for: Self.domainSeparated(data, domain: domain),
                using: signingKey))
    }
}

enum DatabaseContinuationOperation: String, Codable, Hashable, Sendable {
    case browse
    case query
}

struct DatabaseContinuationTimestamp: Codable, Hashable, Sendable {
    let bitPattern: UInt64

    init(_ date: Date) {
        bitPattern = date.timeIntervalSinceReferenceDate.bitPattern
    }
}

struct DatabaseContinuationContextDigests: Codable, Hashable, Sendable {
    let request: Data
    let connection: Data
    let target: Data
    let filter: Data
    let sorts: Data
    let projection: Data
    let consistency: Data
    let query: Data?

    var allDigestsHaveExpectedLength: Bool {
        [request, connection, target, filter, sorts, projection, consistency]
            .allSatisfy { $0.count == SHA256.byteCount }
            && query.map { $0.count == SHA256.byteCount } != false
    }
}

struct DatabaseContinuationTokenHeader: Codable, Hashable, Sendable {
    let version: Int
    let audience: String
    let identifier: UUID
    let operation: DatabaseContinuationOperation
    let context: DatabaseContinuationContextDigests
    let mode: DatabasePagingMode
    let issuedAt: DatabaseContinuationTimestamp
    let expiresAt: DatabaseContinuationTimestamp
}

struct DatabaseContinuationSignedEnvelope: Codable, Hashable, Sendable {
    let header: DatabaseContinuationTokenHeader
    let sealedPayload: Data
}

struct DatabaseContinuationProtectedPayload: Codable, Hashable, Sendable {
    let mode: DatabasePagingMode
    let payload: Data
    let adapterExpiresAt: DatabaseContinuationTimestamp?
}

private struct DatabaseContinuationPageBinding: Codable, Hashable, Sendable {
    let pageSize: DatabasePageSize
    let projection: DatabaseProjection?
    let filter: DatabaseFilter?
    let sorts: [DatabaseSort]
    let consistency: DatabaseConsistencyPreference
}

private struct DatabaseContinuationQueryBinding: Codable, Hashable, Sendable {
    let language: DatabaseQueryLanguage
    let command: String
    let parameters: [DatabaseQueryParameter]
    let body: DatabaseValue?
}

private struct DatabaseContinuationRequestBinding: Sendable {
    let version: Int
    let operation: DatabaseContinuationOperation
    let connectionID: DatabaseConnectionID
    let target: DatabaseTargetIdentifier
    let page: DatabaseContinuationPageBinding
    let query: DatabaseContinuationQueryBinding?
}

private struct DatabaseContinuationAggregateBinding: Codable, Hashable, Sendable {
    let version: Int
    let operation: DatabaseContinuationOperation
    let connectionID: DatabaseConnectionID
    let target: DatabaseTargetIdentifier
    let pageSize: DatabasePageSize
    let connectionDigest: Data
    let targetDigest: Data
    let filterDigest: Data
    let sortsDigest: Data
    let projectionDigest: Data
    let consistencyDigest: Data
    let queryDigest: Data?
}

private struct DatabaseContinuationOptionalFilter: Codable, Hashable, Sendable {
    let value: DatabaseFilter?
}

private struct DatabaseContinuationOptionalProjection: Codable, Hashable, Sendable {
    let value: DatabaseProjection?
}

extension DatabaseContinuationAuthority {
    private static func binding(
        for request: DatabaseBrowseRequest
    ) throws -> DatabaseContinuationRequestBinding {
        let page = DatabasePageRequest(
            pageSize: request.page.pageSize,
            projection: request.page.projection,
            filter: request.page.filter,
            sorts: request.page.sorts,
            consistency: request.page.consistency)
        let validated = DatabaseBrowseRequest(
            version: request.version,
            target: request.target,
            page: page)
        do {
            try DatabaseExecutionValidator().validate(validated)
        } catch {
            throw DatabaseContinuationAuthorityError.invalidRequest
        }
        return DatabaseContinuationRequestBinding(
            version: request.version,
            operation: .browse,
            connectionID: request.target.connectionID,
            target: request.target,
            page: DatabaseContinuationPageBinding(
                pageSize: page.pageSize,
                projection: page.projection,
                filter: page.filter,
                sorts: page.sorts,
                consistency: page.consistency),
            query: nil)
    }

    private static func binding(
        for request: DatabaseQueryRequest
    ) throws -> DatabaseContinuationRequestBinding {
        let page = DatabasePageRequest(
            pageSize: request.page.pageSize,
            projection: request.page.projection,
            filter: request.page.filter,
            sorts: request.page.sorts,
            consistency: request.page.consistency)
        let validated = DatabaseQueryRequest(
            version: request.version,
            target: request.target,
            language: request.language,
            command: request.command,
            parameters: request.parameters,
            body: request.body,
            page: page)
        do {
            try DatabaseExecutionValidator().validate(validated)
        } catch {
            throw DatabaseContinuationAuthorityError.invalidRequest
        }
        return DatabaseContinuationRequestBinding(
            version: request.version,
            operation: .query,
            connectionID: request.target.connectionID,
            target: request.target,
            page: DatabaseContinuationPageBinding(
                pageSize: page.pageSize,
                projection: page.projection,
                filter: page.filter,
                sorts: page.sorts,
                consistency: page.consistency),
            query: DatabaseContinuationQueryBinding(
                language: request.language,
                command: request.command,
                parameters: request.parameters,
                body: request.body))
    }

    private static func domainSeparated(_ data: Data, domain: String) -> Data {
        var authenticated = Data("\(tokenAudience):\(domain)".utf8)
        authenticated.append(0)
        authenticated.append(data)
        return authenticated
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try encoder().encode(value)
        } catch {
            throw DatabaseContinuationAuthorityError.invalidRequest
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func validateFinite(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
    }

    private static func date(
        from timestamp: DatabaseContinuationTimestamp
    ) throws -> Date {
        let interval = TimeInterval(bitPattern: timestamp.bitPattern)
        guard interval.isFinite else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    private static func matches(
        _ first: DatabaseContinuationContextDigests,
        _ second: DatabaseContinuationContextDigests
    ) -> Bool {
        constantTimeEqual(first.request, second.request)
            && constantTimeEqual(first.connection, second.connection)
            && constantTimeEqual(first.target, second.target)
            && constantTimeEqual(first.filter, second.filter)
            && constantTimeEqual(first.sorts, second.sorts)
            && constantTimeEqual(first.projection, second.projection)
            && constantTimeEqual(first.consistency, second.consistency)
            && optionalConstantTimeEqual(first.query, second.query)
    }

    private static func optionalConstantTimeEqual(_ first: Data?, _ second: Data?) -> Bool {
        switch (first, second) {
        case let (.some(first), .some(second)):
            constantTimeEqual(first, second)
        case (.none, .none):
            true
        case (.some, .none), (.none, .some):
            false
        }
    }

    private static func constantTimeEqual(_ first: Data, _ second: Data) -> Bool {
        guard first.count == second.count else { return false }
        var difference: UInt8 = 0
        for index in first.indices {
            difference |= first[index] ^ second[index]
        }
        return difference == 0
    }
}

extension Data {
    fileprivate init?(databaseContinuationBase64URL value: String) {
        guard !value.isEmpty,
            value.unicodeScalars.allSatisfy({ scalar in
                (48...57).contains(scalar.value)
                    || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || scalar.value == 45 || scalar.value == 95
            })
        else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    fileprivate func databaseContinuationBase64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
