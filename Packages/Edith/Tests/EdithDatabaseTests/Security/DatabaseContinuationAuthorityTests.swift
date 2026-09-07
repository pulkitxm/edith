import CryptoKit
import Foundation
import Testing

@testable import EdithDatabase

private final class DatabaseContinuationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private enum DatabaseContinuationFixtures {
    static let signingKey = Data((0..<32).map(UInt8.init))
    static let issuedAt = Date(timeIntervalSince1970: 10_000)
    static let connectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "10940A84-5CC8-49B9-953A-DA80022AB949")!)
    static let otherConnectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "DF3C4C12-4247-4A35-A0C7-FCDCB35909F2")!)
    static let payload = Data("server-cursor-private-material".utf8)

    static var projection: DatabaseProjection {
        DatabaseProjection(
            mode: .include,
            fields: [
                DatabaseProjectedField(path: DatabaseFieldPath("id")),
                DatabaseProjectedField(
                    path: DatabaseFieldPath(["customer", "name"]),
                    alias: "customerName"),
            ])
    }

    static var filter: DatabaseFilter {
        .all([
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("state"),
                    operation: .equal,
                    values: [.string("active")],
                    caseSensitivity: .insensitive)),
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("amount"),
                    operation: .greaterThan,
                    values: [.decimal(DatabaseDecimalValue(rawValue: "10.50"))])),
        ])
    }

    static var sorts: [DatabaseSort] {
        [
            DatabaseSort(
                field: DatabaseFieldPath("createdAt"),
                direction: .descending,
                nullPlacement: .last)
        ]
    }

    static func page(
        size: Int = 40,
        continuation: DatabaseContinuationToken? = nil,
        projection: DatabaseProjection? = DatabaseContinuationFixtures.projection,
        filter: DatabaseFilter? = DatabaseContinuationFixtures.filter,
        sorts: [DatabaseSort] = DatabaseContinuationFixtures.sorts,
        consistency: DatabaseConsistencyPreference = .snapshot
    ) throws -> DatabasePageRequest {
        DatabasePageRequest(
            pageSize: try DatabasePageSize(size),
            continuation: continuation,
            projection: projection,
            filter: filter,
            sorts: sorts,
            consistency: consistency)
    }

    static func target(
        connectionID: DatabaseConnectionID = connectionID,
        path: [String] = ["sales", "orders"]
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .table, path: path))
    }

    static func browse(
        connectionID: DatabaseConnectionID = connectionID,
        path: [String] = ["sales", "orders"],
        page: DatabasePageRequest? = nil,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) throws -> DatabaseBrowseRequest {
        DatabaseBrowseRequest(
            target: target(connectionID: connectionID, path: path),
            page: try page ?? Self.page(),
            operation: operation)
    }

    static func query(
        connectionID: DatabaseConnectionID = connectionID,
        path: [String] = ["sales", "orders"],
        command: String = "find",
        parameters: [DatabaseQueryParameter] = [
            DatabaseQueryParameter(name: "tenant", value: .string("north"))
        ],
        body: DatabaseValue? = .object([
            DatabaseObjectField(name: "state", value: .string("active")),
            DatabaseObjectField(name: "limit", value: .signedInteger(40)),
        ]),
        page: DatabasePageRequest? = nil,
        operation: DatabaseOperationContext = DatabaseOperationContext()
    ) throws -> DatabaseQueryRequest {
        DatabaseQueryRequest(
            target: target(connectionID: connectionID, path: path),
            language: .mongoQuery,
            command: command,
            parameters: parameters,
            body: body,
            page: try page ?? Self.page(),
            operation: operation)
    }

    static func continuation(
        mode: DatabasePagingMode = .serverCursor,
        payload: Data = payload,
        expiresAt: Date? = issuedAt.addingTimeInterval(120)
    ) throws -> DatabaseAdapterContinuation {
        try DatabaseAdapterContinuation(
            mode: mode,
            payload: payload,
            expiresAt: expiresAt)
    }

    static func authority(
        clock: DatabaseContinuationTestClock,
        signingKey: Data = signingKey
    ) throws -> DatabaseContinuationAuthority {
        try DatabaseContinuationAuthority(
            signingKey: signingKey,
            currentDate: { clock.now() })
    }

    static func tokenParts(
        _ token: DatabaseContinuationToken
    ) throws -> (header: Data, sealedPayload: Data, signature: Data) {
        let parts = token.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            let header = Data(continuationTestBase64URL: String(parts[0])),
            let sealedPayload = Data(continuationTestBase64URL: String(parts[1])),
            let signature = Data(continuationTestBase64URL: String(parts[2]))
        else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        return (header, sealedPayload, signature)
    }

    static func header(
        from token: DatabaseContinuationToken
    ) throws -> DatabaseContinuationTokenHeader {
        try decoder().decode(
            DatabaseContinuationTokenHeader.self,
            from: tokenParts(token).header)
    }

    static func signedToken(
        header: DatabaseContinuationTokenHeader,
        sealedPayload: Data,
        signingKey: Data = signingKey,
        transportedHeader: Data? = nil
    ) throws -> DatabaseContinuationToken {
        let headerData = try encoder().encode(header)
        let envelopeData = try encoder().encode(
            DatabaseContinuationSignedEnvelope(
                header: header,
                sealedPayload: sealedPayload))
        var authenticated = Data(
            "\(DatabaseContinuationAuthority.tokenAudience):token".utf8)
        authenticated.append(0)
        authenticated.append(envelopeData)
        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: authenticated,
                using: SymmetricKey(data: signingKey)))
        return DatabaseContinuationToken(
            rawValue:
                "\((transportedHeader ?? headerData).continuationTestBase64URLString()).\(sealedPayload.continuationTestBase64URLString()).\(signature.continuationTestBase64URLString())"
        )
    }

    static func sealedPayload(
        _ payload: DatabaseContinuationProtectedPayload,
        header: DatabaseContinuationTokenHeader,
        signingKey: Data = signingKey
    ) throws -> Data {
        let inputKey = SymmetricKey(data: signingKey)
        let encryptionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(DatabaseContinuationAuthority.tokenAudience.utf8),
            info: Data("payload-encryption".utf8),
            outputByteCount: 32)
        return try ChaChaPoly.seal(
            encoder().encode(payload),
            using: encryptionKey,
            authenticating: encoder().encode(header)
        ).combined
    }

    static func sealedBytes(
        _ bytes: Data,
        header: DatabaseContinuationTokenHeader,
        signingKey: Data = signingKey
    ) throws -> Data {
        let inputKey = SymmetricKey(data: signingKey)
        let encryptionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(DatabaseContinuationAuthority.tokenAudience.utf8),
            info: Data("payload-encryption".utf8),
            outputByteCount: 32)
        return try ChaChaPoly.seal(
            bytes,
            using: encryptionKey,
            authenticating: encoder().encode(header)
        ).combined
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func reversedTopLevelJSON(_ data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DatabaseContinuationAuthorityError.malformedToken
        }
        let fields = try object.keys.sorted(by: >).map { key in
            let keyData = try JSONSerialization.data(withJSONObject: [key])
            let keyText = String(decoding: keyData.dropFirst().dropLast(), as: UTF8.self)
            let valueData = try JSONSerialization.data(
                withJSONObject: object[key] as Any,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            return "\(keyText):\(String(decoding: valueData, as: UTF8.self))"
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    static func contains(_ haystack: Data, subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return haystack.indices.dropLast(needle.count - 1).contains { start in
            haystack[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

@Suite struct DatabaseContinuationAuthorityTests {
    @Test func browseAndQueryRoundTripWithoutExposingAdapterMaterial() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let continuation = try DatabaseContinuationFixtures.continuation()
        let browse = try DatabaseContinuationFixtures.browse()
        let browseToken = try authority.issue(continuation, for: browse, lifetimeSeconds: 90)
        let resumedBrowse = try DatabaseContinuationFixtures.browse(
            page: DatabaseContinuationFixtures.page(continuation: browseToken),
            operation: DatabaseOperationContext(
                operationID: DatabaseOperationID(),
                deadline: DatabaseContinuationFixtures.issuedAt.addingTimeInterval(30)))

        #expect(try authority.open(browseToken, for: resumedBrowse) == continuation)
        #expect(browseToken.rawValue.utf8.count <= DatabaseContinuationAuthority.maximumTokenBytes)

        let query = try DatabaseContinuationFixtures.query()
        let queryToken = try authority.issue(continuation, for: query, lifetimeSeconds: 90)
        let resumedQuery = try DatabaseContinuationFixtures.query(
            page: DatabaseContinuationFixtures.page(continuation: queryToken),
            operation: DatabaseOperationContext())

        #expect(try authority.open(queryToken, for: resumedQuery) == continuation)
        #expect(throws: DatabaseContinuationAuthorityError.contextMismatch) {
            try authority.open(queryToken, for: browse)
        }

        let queryParts = try DatabaseContinuationFixtures.tokenParts(queryToken)
        let transported = queryParts.header + queryParts.sealedPayload + queryParts.signature
        let sensitiveValues = [
            DatabaseContinuationFixtures.payload,
            DatabaseContinuationFixtures.signingKey,
            Data("find".utf8),
            Data("north".utf8),
            Data("active".utf8),
        ]
        for value in sensitiveValues {
            #expect(!DatabaseContinuationFixtures.contains(transported, subsequence: value))
            #expect(!queryToken.rawValue.contains(value.base64EncodedString()))
            #expect(!queryToken.rawValue.contains(value.continuationTestBase64URLString()))
        }
    }

    @Test func contextRejectsConnectionTargetAndPagingSemanticChanges() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let request = try DatabaseContinuationFixtures.browse()
        let token = try authority.issue(
            DatabaseContinuationFixtures.continuation(),
            for: request)
        let variants = [
            try DatabaseContinuationFixtures.browse(
                connectionID: DatabaseContinuationFixtures.otherConnectionID),
            try DatabaseContinuationFixtures.browse(path: ["sales", "customers"]),
            try DatabaseContinuationFixtures.browse(
                page: DatabaseContinuationFixtures.page(size: 41)),
            try DatabaseContinuationFixtures.browse(
                page: DatabaseContinuationFixtures.page(
                    projection: DatabaseProjection(
                        mode: .exclude,
                        fields: [DatabaseProjectedField(path: DatabaseFieldPath("secret"))]))),
            try DatabaseContinuationFixtures.browse(
                page: DatabaseContinuationFixtures.page(
                    filter: .predicate(
                        DatabaseFilterPredicate(
                            field: DatabaseFieldPath("state"),
                            operation: .equal,
                            values: [.string("closed")])))),
            try DatabaseContinuationFixtures.browse(
                page: DatabaseContinuationFixtures.page(
                    sorts: [
                        DatabaseSort(
                            field: DatabaseFieldPath("createdAt"),
                            direction: .ascending)
                    ])),
            try DatabaseContinuationFixtures.browse(
                page: DatabaseContinuationFixtures.page(consistency: .strong)),
        ]

        for variant in variants {
            #expect(throws: DatabaseContinuationAuthorityError.contextMismatch) {
                try authority.open(token, for: variant)
            }
        }
    }

    @Test func queryIdentityRejectsCommandParameterAndBodyChanges() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let request = try DatabaseContinuationFixtures.query()
        let token = try authority.issue(
            DatabaseContinuationFixtures.continuation(),
            for: request)
        let variants = [
            try DatabaseContinuationFixtures.query(command: "aggregate"),
            try DatabaseContinuationFixtures.query(
                parameters: [
                    DatabaseQueryParameter(name: "tenant", value: .string("south"))
                ]),
            try DatabaseContinuationFixtures.query(
                body: .object([
                    DatabaseObjectField(name: "state", value: .string("closed")),
                    DatabaseObjectField(name: "limit", value: .signedInteger(40)),
                ])),
            try DatabaseContinuationFixtures.query(
                body: .object([
                    DatabaseObjectField(name: "limit", value: .signedInteger(40)),
                    DatabaseObjectField(name: "state", value: .string("active")),
                ])),
        ]

        for variant in variants {
            #expect(throws: DatabaseContinuationAuthorityError.contextMismatch) {
                try authority.open(token, for: variant)
            }
        }
    }

    @Test func expiryFutureIssueTimeAndAdapterExpiryAreEnforced() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let adapterExpiry = DatabaseContinuationFixtures.issuedAt.addingTimeInterval(20)
        let continuation = try DatabaseContinuationFixtures.continuation(
            expiresAt: adapterExpiry)
        let request = try DatabaseContinuationFixtures.browse()
        let token = try authority.issue(continuation, for: request, lifetimeSeconds: 60)
        let header = try DatabaseContinuationFixtures.header(from: token)

        #expect(
            Date(
                timeIntervalSinceReferenceDate: TimeInterval(
                    bitPattern: header.expiresAt.bitPattern)) == adapterExpiry)

        clock.set(DatabaseContinuationFixtures.issuedAt.addingTimeInterval(-31))
        #expect(throws: DatabaseContinuationAuthorityError.issuedInFuture) {
            try authority.open(token, for: request)
        }

        clock.set(adapterExpiry)
        #expect(throws: DatabaseContinuationAuthorityError.expired) {
            try authority.open(token, for: request)
        }

        clock.set(DatabaseContinuationFixtures.issuedAt)
        #expect(throws: DatabaseContinuationAuthorityError.expired) {
            try authority.issue(
                DatabaseContinuationFixtures.continuation(
                    expiresAt: DatabaseContinuationFixtures.issuedAt),
                for: request)
        }
        #expect(throws: DatabaseContinuationAuthorityError.invalidLifetimeSeconds(0)) {
            try authority.issue(continuation, for: request, lifetimeSeconds: 0)
        }
        #expect(
            throws: DatabaseContinuationAuthorityError.invalidLifetimeSeconds(
                DatabaseContinuationAuthority.lifetimeSecondRange.upperBound + 1)
        ) {
            try authority.issue(
                continuation,
                for: request,
                lifetimeSeconds: DatabaseContinuationAuthority.lifetimeSecondRange.upperBound + 1)
        }
    }

    @Test func tamperingMalformedTokensAndIncorrectSignaturesAreRejected() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let request = try DatabaseContinuationFixtures.browse()
        let token = try authority.issue(
            DatabaseContinuationFixtures.continuation(),
            for: request)
        let parts = try DatabaseContinuationFixtures.tokenParts(token)
        var changedPayload = parts.sealedPayload
        changedPayload[changedPayload.startIndex] ^= 1
        let tamperedPayload = DatabaseContinuationToken(
            rawValue:
                "\(parts.header.continuationTestBase64URLString()).\(changedPayload.continuationTestBase64URLString()).\(parts.signature.continuationTestBase64URLString())"
        )

        #expect(throws: DatabaseContinuationAuthorityError.invalidSignature) {
            try authority.open(tamperedPayload, for: request)
        }

        var changedSignature = parts.signature
        changedSignature[changedSignature.startIndex] ^= 1
        let incorrectSignature = DatabaseContinuationToken(
            rawValue:
                "\(parts.header.continuationTestBase64URLString()).\(parts.sealedPayload.continuationTestBase64URLString()).\(changedSignature.continuationTestBase64URLString())"
        )
        #expect(throws: DatabaseContinuationAuthorityError.invalidSignature) {
            try authority.open(incorrectSignature, for: request)
        }

        let malformed = [
            DatabaseContinuationToken(rawValue: ""),
            DatabaseContinuationToken(rawValue: "invalid"),
            DatabaseContinuationToken(rawValue: "a.b.c.d"),
            DatabaseContinuationToken(rawValue: "a=.b.c"),
            DatabaseContinuationToken(rawValue: "a.+.c"),
            DatabaseContinuationToken(
                rawValue: String(
                    repeating: "x",
                    count: DatabaseContinuationAuthority.maximumTokenBytes + 1)),
        ]
        for malformedToken in malformed {
            #expect(throws: DatabaseContinuationAuthorityError.malformedToken) {
                try authority.open(malformedToken, for: request)
            }
        }
    }

    @Test func signedVersionAudienceLifetimeAndPayloadViolationsAreRejected() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let request = try DatabaseContinuationFixtures.browse()
        let token = try authority.issue(
            DatabaseContinuationFixtures.continuation(),
            for: request)
        let parts = try DatabaseContinuationFixtures.tokenParts(token)
        let header = try DatabaseContinuationFixtures.header(from: token)
        let unsupportedHeader = DatabaseContinuationTokenHeader(
            version: header.version + 1,
            audience: header.audience,
            identifier: header.identifier,
            operation: header.operation,
            context: header.context,
            mode: header.mode,
            issuedAt: header.issuedAt,
            expiresAt: header.expiresAt)
        let unsupported = try DatabaseContinuationFixtures.signedToken(
            header: unsupportedHeader,
            sealedPayload: parts.sealedPayload)
        #expect(
            throws: DatabaseContinuationAuthorityError.unsupportedVersion(
                DatabaseContinuationAuthority.tokenSchemaVersion + 1)
        ) {
            try authority.open(unsupported, for: request)
        }

        let audienceHeader = DatabaseContinuationTokenHeader(
            version: header.version,
            audience: "com.example.other-audience",
            identifier: header.identifier,
            operation: header.operation,
            context: header.context,
            mode: header.mode,
            issuedAt: header.issuedAt,
            expiresAt: header.expiresAt)
        let wrongAudience = try DatabaseContinuationFixtures.signedToken(
            header: audienceHeader,
            sealedPayload: parts.sealedPayload)
        #expect(throws: DatabaseContinuationAuthorityError.invalidAudience) {
            try authority.open(wrongAudience, for: request)
        }

        let excessiveExpiry = DatabaseContinuationTimestamp(
            DatabaseContinuationFixtures.issuedAt.addingTimeInterval(
                TimeInterval(DatabaseContinuationAuthority.lifetimeSecondRange.upperBound + 1)))
        let excessiveLifetimeHeader = DatabaseContinuationTokenHeader(
            version: header.version,
            audience: header.audience,
            identifier: header.identifier,
            operation: header.operation,
            context: header.context,
            mode: header.mode,
            issuedAt: header.issuedAt,
            expiresAt: excessiveExpiry)
        let excessiveLifetime = try DatabaseContinuationFixtures.signedToken(
            header: excessiveLifetimeHeader,
            sealedPayload: parts.sealedPayload)
        #expect(throws: DatabaseContinuationAuthorityError.lifetimeExceeded) {
            try authority.open(excessiveLifetime, for: request)
        }

        let oversizedProtectedPayload = DatabaseContinuationProtectedPayload(
            mode: header.mode,
            payload: Data(
                count: DatabaseAdapterBounds.maximumContinuationBytes + 1),
            adapterExpiresAt: DatabaseContinuationTimestamp(
                DatabaseContinuationFixtures.issuedAt.addingTimeInterval(120)))
        let oversizedSealed = try DatabaseContinuationFixtures.sealedPayload(
            oversizedProtectedPayload,
            header: header)
        let oversizedPayload = try DatabaseContinuationFixtures.signedToken(
            header: header,
            sealedPayload: oversizedSealed)
        #expect(
            throws: DatabaseContinuationAuthorityError.payloadLimitExceeded(
                actual: DatabaseAdapterBounds.maximumContinuationBytes + 1,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        ) {
            try authority.open(oversizedPayload, for: request)
        }

        let malformedSealed = try DatabaseContinuationFixtures.sealedBytes(
            Data("{".utf8),
            header: header)
        let malformedPayload = try DatabaseContinuationFixtures.signedToken(
            header: header,
            sealedPayload: malformedSealed)
        #expect(throws: DatabaseContinuationAuthorityError.malformedPayload) {
            try authority.open(malformedPayload, for: request)
        }

        let canonicalProtectedPayload = try DatabaseContinuationFixtures.encoder().encode(
            DatabaseContinuationProtectedPayload(
                mode: header.mode,
                payload: DatabaseContinuationFixtures.payload,
                adapterExpiresAt: DatabaseContinuationTimestamp(
                    DatabaseContinuationFixtures.issuedAt.addingTimeInterval(120))))
        let noncanonicalProtectedPayload = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: canonicalProtectedPayload),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        #expect(noncanonicalProtectedPayload != canonicalProtectedPayload)
        let noncanonicalSealed = try DatabaseContinuationFixtures.sealedBytes(
            noncanonicalProtectedPayload,
            header: header)
        let noncanonicalPayload = try DatabaseContinuationFixtures.signedToken(
            header: header,
            sealedPayload: noncanonicalSealed)
        #expect(throws: DatabaseContinuationAuthorityError.malformedPayload) {
            try authority.open(noncanonicalPayload, for: request)
        }

        let mismatchedModePayload = DatabaseContinuationProtectedPayload(
            mode: .offset,
            payload: DatabaseContinuationFixtures.payload,
            adapterExpiresAt: DatabaseContinuationTimestamp(
                DatabaseContinuationFixtures.issuedAt.addingTimeInterval(120)))
        let mismatchedModeSealed = try DatabaseContinuationFixtures.sealedPayload(
            mismatchedModePayload,
            header: header)
        let mismatchedMode = try DatabaseContinuationFixtures.signedToken(
            header: header,
            sealedPayload: mismatchedModeSealed)
        #expect(throws: DatabaseContinuationAuthorityError.malformedPayload) {
            try authority.open(mismatchedMode, for: request)
        }

        let malformedContext = DatabaseContinuationContextDigests(
            request: Data(header.context.request.dropLast()),
            connection: header.context.connection,
            target: header.context.target,
            filter: header.context.filter,
            sorts: header.context.sorts,
            projection: header.context.projection,
            consistency: header.context.consistency,
            query: header.context.query)
        let malformedContextHeader = DatabaseContinuationTokenHeader(
            version: header.version,
            audience: header.audience,
            identifier: header.identifier,
            operation: header.operation,
            context: malformedContext,
            mode: header.mode,
            issuedAt: header.issuedAt,
            expiresAt: header.expiresAt)
        let malformedContextToken = try DatabaseContinuationFixtures.signedToken(
            header: malformedContextHeader,
            sealedPayload: parts.sealedPayload)
        #expect(throws: DatabaseContinuationAuthorityError.malformedToken) {
            try authority.open(malformedContextToken, for: request)
        }
    }

    @Test func signingKeyAndAdapterPayloadBoundsAreStrict() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        for count in [
            DatabaseContinuationAuthority.signingKeyByteRange.lowerBound - 1,
            DatabaseContinuationAuthority.signingKeyByteRange.upperBound + 1,
        ] {
            #expect(
                throws: DatabaseContinuationAuthorityError.invalidSigningKeyBytes(count)
            ) {
                try DatabaseContinuationFixtures.authority(
                    clock: clock,
                    signingKey: Data(count: count))
            }
        }
        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .continuationBytes,
                actual: DatabaseAdapterBounds.maximumContinuationBytes + 1,
                maximum: DatabaseAdapterBounds.maximumContinuationBytes)
        ) {
            try DatabaseAdapterContinuation(
                mode: .serverCursor,
                payload: Data(count: DatabaseAdapterBounds.maximumContinuationBytes + 1))
        }
    }

    @Test func maximumAdapterPayloadFitsBoundedPublicToken() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let continuation = try DatabaseContinuationFixtures.continuation(
            payload: Data(count: DatabaseAdapterBounds.maximumContinuationBytes),
            expiresAt: nil)
        let request = try DatabaseContinuationFixtures.browse()
        let token = try authority.issue(continuation, for: request)

        #expect(token.rawValue.utf8.count <= DatabaseContinuationAuthority.maximumTokenBytes)
        #expect(try authority.open(token, for: request) == continuation)
    }

    @Test func factoryRaceSharesIndependentDedicatedSigningKey() async throws {
        let store = try InMemoryDatabaseSecretStore()
        async let first = DatabaseContinuationAuthority.create(secretStore: store)
        async let second = DatabaseContinuationAuthority.create(secretStore: store)
        let (issuer, opener) = try await (first, second)
        let request = try DatabaseContinuationFixtures.browse()
        let continuation = try DatabaseContinuationFixtures.continuation(expiresAt: nil)
        let token = try issuer.issue(continuation, for: request)

        #expect(try opener.open(token, for: request) == continuation)
        #expect(
            try await store.read(DatabaseContinuationAuthority.signingKeyReference).count
                == DatabaseContinuationAuthority.signingKeyByteRange.lowerBound)
        #expect(
            DatabaseContinuationAuthority.signingKeyReference.purpose
                == .continuationSigningKey)
        #expect(
            DatabaseContinuationAuthority.signingKeyReference
                != DatabaseConfirmationAuthority.signingKeyReference)
    }

    @Test func canonicalHeaderAndContextDigestsAreDeterministic() throws {
        let clock = DatabaseContinuationTestClock(DatabaseContinuationFixtures.issuedAt)
        let authority = try DatabaseContinuationFixtures.authority(clock: clock)
        let request = try DatabaseContinuationFixtures.query()
        let continuation = try DatabaseContinuationFixtures.continuation()
        let first = try authority.issue(continuation, for: request)
        let equivalent = try DatabaseContinuationFixtures.query(
            operation: DatabaseOperationContext(
                operationID: DatabaseOperationID(),
                deadline: DatabaseContinuationFixtures.issuedAt.addingTimeInterval(15)))
        let second = try authority.issue(continuation, for: equivalent)
        let firstHeader = try DatabaseContinuationFixtures.header(from: first)
        let secondHeader = try DatabaseContinuationFixtures.header(from: second)

        #expect(firstHeader.context == secondHeader.context)
        #expect(firstHeader.identifier != secondHeader.identifier)

        let parts = try DatabaseContinuationFixtures.tokenParts(first)
        let reordered = try DatabaseContinuationFixtures.reversedTopLevelJSON(parts.header)
        #expect(reordered != parts.header)
        let noncanonical = try DatabaseContinuationFixtures.signedToken(
            header: firstHeader,
            sealedPayload: parts.sealedPayload,
            transportedHeader: reordered)
        #expect(throws: DatabaseContinuationAuthorityError.malformedToken) {
            try authority.open(noncanonical, for: request)
        }
    }
}

extension Data {
    fileprivate init?(continuationTestBase64URL value: String) {
        guard !value.isEmpty else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }

    fileprivate func continuationTestBase64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
