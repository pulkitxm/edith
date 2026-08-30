import CryptoKit
import Foundation

public enum DatabaseDestructiveAction: String, CaseIterable, Codable, Hashable, Sendable {
    case insert
    case update
    case updateMany
    case delete
    case deleteMany
    case truncate
    case dropObject
    case schemaChange
    case permissionChange
    case terminateSession
    case maintenance
    case reindex
    case asynchronousMutation
}

public enum DatabaseMutationScope: String, CaseIterable, Codable, Hashable, Sendable {
    case singleRecord
    case selectedRecords
    case predicate
    case entireObject
}

public enum DatabaseTransactionBehavior: String, CaseIterable, Codable, Hashable, Sendable {
    case transactional
    case nontransactional
    case asynchronous
    case productDependent
}

public enum DatabaseRollbackAvailability: String, CaseIterable, Codable, Hashable, Sendable {
    case available
    case unavailable
    case conditional
}

public enum DatabaseExecutionMode: String, CaseIterable, Codable, Hashable, Sendable {
    case synchronous
    case asynchronous
}

public enum DatabaseMutationPayloadKind: String, CaseIterable, Codable, Hashable, Sendable {
    case sql
    case keyspace
    case document
    case search
    case analytical
    case administrative
}

public struct DatabaseMutationParameter: Codable, Hashable, Sendable {
    public let name: String
    public let value: DatabaseValue

    public init(name: String, value: DatabaseValue) {
        self.name = name
        self.value = value
    }
}

public enum DatabaseValuePreviewKind: String, CaseIterable, Codable, Hashable, Sendable {
    case missing
    case null
    case boolean
    case signedInteger
    case unsignedInteger
    case decimal
    case floatingPoint
    case string
    case binary
    case date
    case time
    case timestamp
    case uuid
    case array
    case object
    case productSpecific
}

public struct DatabaseMutationParameterPreview: Codable, Hashable, Sendable {
    public let name: String
    public let valueKind: DatabaseValuePreviewKind

    init(name: String, valueKind: DatabaseValuePreviewKind) {
        self.name = name
        self.valueKind = valueKind
    }
}

public enum DatabaseMutationPayload: Codable, Hashable, Sendable {
    case relational(
        product: DatabaseProduct,
        statement: String,
        parameters: [DatabaseMutationParameter])
    case keyspace(
        product: DatabaseProduct,
        command: String,
        arguments: [DatabaseMutationParameter])
    case document(
        product: DatabaseProduct,
        operation: String,
        parameters: [DatabaseMutationParameter],
        body: DatabaseValue)
    case search(
        product: DatabaseProduct,
        operation: String,
        parameters: [DatabaseMutationParameter],
        body: DatabaseValue)
    case analytical(
        product: DatabaseProduct,
        statement: String,
        parameters: [DatabaseMutationParameter])
    case administrative(
        product: DatabaseProduct,
        command: String,
        parameters: [DatabaseMutationParameter],
        body: DatabaseValue?)

    public var product: DatabaseProduct {
        switch self {
        case let .relational(product, _, _),
            let .keyspace(product, _, _),
            let .document(product, _, _, _),
            let .search(product, _, _, _),
            let .analytical(product, _, _),
            let .administrative(product, _, _, _):
            product
        }
    }

    public var kind: DatabaseMutationPayloadKind {
        switch self {
        case .relational:
            .sql
        case .keyspace:
            .keyspace
        case .document:
            .document
        case .search:
            .search
        case .analytical:
            .analytical
        case .administrative:
            .administrative
        }
    }

    public var command: String {
        switch self {
        case let .relational(_, statement, _), let .analytical(_, statement, _):
            statement
        case let .keyspace(_, command, _), let .administrative(_, command, _, _):
            command
        case let .document(_, operation, _, _), let .search(_, operation, _, _):
            operation
        }
    }

    public var parameters: [DatabaseMutationParameter] {
        switch self {
        case let .relational(_, _, parameters),
            let .document(_, _, parameters, _),
            let .search(_, _, parameters, _),
            let .analytical(_, _, parameters),
            let .administrative(_, _, parameters, _):
            parameters
        case let .keyspace(_, _, arguments):
            arguments
        }
    }

    public var body: DatabaseValue? {
        switch self {
        case let .document(_, _, _, body), let .search(_, _, _, body):
            body
        case let .administrative(_, _, _, body):
            body
        case .relational, .keyspace, .analytical:
            nil
        }
    }
}

public struct DatabaseMutationImpact: Codable, Hashable, Sendable {
    public let count: DatabaseCountMetadata
    public let description: String

    public init(count: DatabaseCountMetadata, description: String) {
        self.count = count
        self.description = description
    }
}

public struct DatabaseDestructiveRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let target: DatabaseTargetIdentifier
    public let selectedRecords: [DatabaseRecordIdentity]
    public let predicate: DatabaseFilter?
    public let payload: DatabaseMutationPayload

    public init(
        version: Int = DatabaseDestructiveRequest.schemaVersion,
        target: DatabaseTargetIdentifier,
        selectedRecords: [DatabaseRecordIdentity] = [],
        predicate: DatabaseFilter? = nil,
        payload: DatabaseMutationPayload
    ) {
        self.version = version
        self.target = target
        self.selectedRecords = selectedRecords
        self.predicate = predicate
        self.payload = payload
    }
}

struct DatabaseDestructivePlan: Codable, Hashable, Sendable {
    let request: DatabaseDestructiveRequest
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let impact: DatabaseMutationImpact
    let transactionBehavior: DatabaseTransactionBehavior
    let rollbackAvailability: DatabaseRollbackAvailability
    let executionMode: DatabaseExecutionMode
    let warnings: [DatabaseWarning]

    init(
        request: DatabaseDestructiveRequest,
        action: DatabaseDestructiveAction,
        scope: DatabaseMutationScope,
        impact: DatabaseMutationImpact,
        transactionBehavior: DatabaseTransactionBehavior,
        rollbackAvailability: DatabaseRollbackAvailability,
        executionMode: DatabaseExecutionMode,
        warnings: [DatabaseWarning] = []
    ) {
        self.request = request
        self.action = action
        self.scope = scope
        self.impact = impact
        self.transactionBehavior = transactionBehavior
        self.rollbackAvailability = rollbackAvailability
        self.executionMode = executionMode
        self.warnings = warnings
    }
}

public struct DatabaseMutationPreview: Codable, Hashable, Sendable {
    public let product: DatabaseProduct
    public let kind: DatabaseMutationPayloadKind
    public let command: String
    public let parameters: [DatabaseMutationParameterPreview]
    public let body: DatabaseValue?

    init(
        product: DatabaseProduct,
        kind: DatabaseMutationPayloadKind,
        command: String,
        parameters: [DatabaseMutationParameterPreview],
        body: DatabaseValue?
    ) {
        self.product = product
        self.kind = kind
        self.command = command
        self.parameters = parameters
        self.body = body
    }
}

public enum DatabaseMutationContextKind: String, CaseIterable, Codable, Hashable, Sendable {
    case database
    case cluster
    case logicalDatabase

    public var displayName: String {
        switch self {
        case .database:
            "Database"
        case .cluster:
            "Cluster"
        case .logicalDatabase:
            "Logical database"
        }
    }
}

public struct DatabaseMutationContext: Codable, Hashable, Sendable {
    public let kind: DatabaseMutationContextKind
    public let value: String
    public let catalog: String?
    public let schema: String?

    public init(
        kind: DatabaseMutationContextKind,
        value: String,
        catalog: String? = nil,
        schema: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.catalog = catalog
        self.schema = schema
    }
}

public struct DatabaseDestructiveEffect: Codable, Hashable, Sendable {
    public let action: DatabaseDestructiveAction
    public let connection: DatabaseConnectionIdentity
    public let context: DatabaseMutationContext
    public let target: DatabaseTargetIdentifier
    public let selectedRecords: [DatabaseRecordIdentity]
    public let predicate: DatabaseFilter?
    public let scope: DatabaseMutationScope
    public let impact: DatabaseMutationImpact
    public let transactionBehavior: DatabaseTransactionBehavior
    public let rollbackAvailability: DatabaseRollbackAvailability
    public let executionMode: DatabaseExecutionMode
    public let executionDigest: String
    public let displayDigest: String

    init(
        action: DatabaseDestructiveAction,
        connection: DatabaseConnectionIdentity,
        context: DatabaseMutationContext,
        target: DatabaseTargetIdentifier,
        selectedRecords: [DatabaseRecordIdentity],
        predicate: DatabaseFilter?,
        scope: DatabaseMutationScope,
        impact: DatabaseMutationImpact,
        transactionBehavior: DatabaseTransactionBehavior,
        rollbackAvailability: DatabaseRollbackAvailability,
        executionMode: DatabaseExecutionMode,
        executionDigest: String,
        displayDigest: String
    ) {
        self.action = action
        self.connection = connection
        self.context = context
        self.target = target
        self.selectedRecords = selectedRecords
        self.predicate = predicate
        self.scope = scope
        self.impact = impact
        self.transactionBehavior = transactionBehavior
        self.rollbackAvailability = rollbackAvailability
        self.executionMode = executionMode
        self.executionDigest = executionDigest
        self.displayDigest = displayDigest
    }
}

public enum DatabaseConfirmationStrength: String, CaseIterable, Codable, Hashable, Sendable {
    case explicit
    case target
    case connectionAndTarget
}

public struct DatabaseRequiredConfirmation: Codable, Hashable, Sendable {
    public let strength: DatabaseConfirmationStrength
    public let text: String

    init(strength: DatabaseConfirmationStrength, text: String) {
        self.strength = strength
        self.text = text
    }
}

public struct DatabaseConfirmationToken: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct DatabaseDestructivePreview: Codable, Hashable, Sendable {
    public let effect: DatabaseDestructiveEffect
    public let request: DatabaseMutationPreview
    public let warnings: [DatabaseWarning]
    public let requiredConfirmation: DatabaseRequiredConfirmation
    public let issuedAt: Date
    public let expiresAt: Date
    public let token: DatabaseConfirmationToken

    init(
        effect: DatabaseDestructiveEffect,
        request: DatabaseMutationPreview,
        warnings: [DatabaseWarning],
        requiredConfirmation: DatabaseRequiredConfirmation,
        issuedAt: Date,
        expiresAt: Date,
        token: DatabaseConfirmationToken
    ) {
        self.effect = effect
        self.request = request
        self.warnings = warnings
        self.requiredConfirmation = requiredConfirmation
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.token = token
    }
}

public enum DatabaseMutationProhibition: String, Codable, Equatable, Sendable {
    case connectionReadOnly
    case environmentReadOnly
    case productionPolicy
}

public enum DatabaseConfirmationError: Error, Equatable, Sendable {
    case invalidSigningKeyBytes(Int)
    case invalidLifetimeSeconds(Int)
    case connectionNotFound(DatabaseConnectionID)
    case productMismatch(expected: DatabaseProduct, actual: DatabaseProduct)
    case mutationProhibited(DatabaseMutationProhibition)
    case invalidRequest(String)
    case limitExceeded(name: String, actual: Int, maximum: Int)
    case malformedToken
    case unsupportedVersion(Int)
    case invalidSignature
    case issuedInFuture
    case expired
    case lifetimeExceeded
    case effectMismatch
    case confirmationTextMismatch
    case alreadyConsumedOrUnknown
}

actor DatabaseConfirmationAuthority {
    static let tokenSchemaVersion = 1
    static let tokenAudience = "com.pulkitxm.edith.database-confirmation"
    static let signingKeyByteRange = 32...64
    static let lifetimeSecondRange = 5...300
    static let maximumClockSkewSeconds = 30
    static let maximumTokenBytes = 4_096
    static let maximumCommandBytes = 65_536
    static let maximumCanonicalPayloadBytes = 1_048_576
    static let maximumDisplayPayloadBytes = 131_072
    static let maximumInputBytes = 1_048_576
    static let maximumInputNodes = 10_000
    static let maximumInputDepth = 32
    static let maximumParameterCount = 512
    static let maximumSelectedRecordCount = 2_000
    static let maximumWarningCount = 32
    static let maximumPathSegmentCount = 64
    static let maximumCollectionCount = 10_000
    static let maximumTextBytes = 65_536
    static let maximumImpactDescriptionBytes = 2_048
    static let maximumWarningMessageBytes = 8_192
    static let maximumConfirmationTextBytes = 4_096

    static let signingKeyReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "03E2EFA4-0654-4D8E-B0BC-4AB7610F44D8")!,
        purpose: .confirmationSigningKey)

    private let signingKey: SymmetricKey
    private let metadataStore: any DatabaseMetadataStore
    private let secretStore: any DatabaseSecretStore
    private let runtimeOwner: DatabaseRuntimeOwnerToken
    private let currentDate: @Sendable () -> Date

    init(
        signingKey: Data,
        metadataStore: any DatabaseMetadataStore,
        secretStore: any DatabaseSecretStore,
        runtimeOwner: DatabaseRuntimeOwnerToken,
        currentDate: @escaping @Sendable () -> Date
    ) throws {
        guard Self.signingKeyByteRange.contains(signingKey.count) else {
            throw DatabaseConfirmationError.invalidSigningKeyBytes(signingKey.count)
        }
        self.signingKey = SymmetricKey(data: signingKey)
        self.metadataStore = metadataStore
        self.secretStore = secretStore
        self.runtimeOwner = runtimeOwner
        self.currentDate = currentDate
    }

    static func create(
        secretStore: any DatabaseSecretStore,
        metadataStore: any DatabaseMetadataStore,
        runtimeOwner: DatabaseRuntimeOwnerToken
    ) async throws -> DatabaseConfirmationAuthority {
        var generator = SystemRandomNumberGenerator()
        let proposedKey = Data(
            (0..<Self.signingKeyByteRange.lowerBound).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            })
        let signingKey = try await secretStore.storeIfAbsent(
            proposedKey,
            for: signingKeyReference)
        return try DatabaseConfirmationAuthority(
            signingKey: signingKey,
            metadataStore: metadataStore,
            secretStore: secretStore,
            runtimeOwner: runtimeOwner,
            currentDate: { Date() })
    }

    func issuePreview(
        for plan: DatabaseDestructivePlan,
        lifetimeSeconds: Int = 120
    ) async throws -> DatabaseDestructivePreview {
        guard Self.lifetimeSecondRange.contains(lifetimeSeconds) else {
            throw DatabaseConfirmationError.invalidLifetimeSeconds(lifetimeSeconds)
        }
        let now = currentDate()
        _ = try await metadataStore.removeExpiredConfirmations(
            before: now,
            limit: DatabaseMetadataMaintenanceBounds.maximumBatchSize,
            owner: runtimeOwner)
        let prepared = try await prepare(plan)
        let identifier = UUID()
        let expiresAt = now.addingTimeInterval(TimeInterval(lifetimeSeconds))
        let payload = DatabaseConfirmationTokenPayload(
            version: Self.tokenSchemaVersion,
            audience: Self.tokenAudience,
            identifier: identifier,
            executionDigest: prepared.executionDigest,
            displayDigest: prepared.displayDigest,
            issuedAt: now,
            expiresAt: expiresAt)
        let payloadData = try Self.encode(payload)
        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: Self.domainSeparated(payloadData, domain: "token"),
                using: signingKey))
        let token = DatabaseConfirmationToken(
            rawValue:
                "\(payloadData.databaseBase64URLString()).\(signature.databaseBase64URLString())")
        guard token.rawValue.utf8.count <= Self.maximumTokenBytes else {
            throw DatabaseConfirmationError.malformedToken
        }
        try await metadataStore.registerConfirmation(
            DatabaseConfirmationReceipt(
                identifier: identifier,
                effectDigest: prepared.receiptDigest,
                expiresAt: expiresAt),
            owner: runtimeOwner)
        return DatabaseDestructivePreview(
            effect: prepared.effect,
            request: prepared.request,
            warnings: prepared.warnings,
            requiredConfirmation: prepared.requiredConfirmation,
            issuedAt: now,
            expiresAt: expiresAt,
            token: token)
    }

    func authorizeAndExecute<Output: Sendable>(
        token: DatabaseConfirmationToken,
        plan: DatabaseDestructivePlan,
        confirmationText: String,
        operation:
            @Sendable (DatabaseConnectionDefinition, DatabaseDestructivePlan) async throws
            -> Output
    ) async throws -> Output {
        let payload = try authenticate(token)
        guard payload.version == Self.tokenSchemaVersion else {
            throw DatabaseConfirmationError.unsupportedVersion(payload.version)
        }
        guard payload.audience == Self.tokenAudience else {
            throw DatabaseConfirmationError.malformedToken
        }
        let now = currentDate()
        guard payload.issuedAt <= now.addingTimeInterval(TimeInterval(Self.maximumClockSkewSeconds))
        else {
            throw DatabaseConfirmationError.issuedInFuture
        }
        guard payload.expiresAt > now else {
            throw DatabaseConfirmationError.expired
        }
        guard
            payload.expiresAt.timeIntervalSince(payload.issuedAt)
                <= TimeInterval(Self.lifetimeSecondRange.upperBound)
        else {
            throw DatabaseConfirmationError.lifetimeExceeded
        }
        let prepared = try await prepare(plan)
        guard Self.constantTimeEqual(payload.executionDigest, prepared.executionDigest),
            Self.constantTimeEqual(payload.displayDigest, prepared.displayDigest)
        else {
            throw DatabaseConfirmationError.effectMismatch
        }
        guard confirmationText == prepared.requiredConfirmation.text else {
            throw DatabaseConfirmationError.confirmationTextMismatch
        }
        let consumed = try await metadataStore.consumeConfirmation(
            identifier: payload.identifier,
            effectDigest: prepared.receiptDigest,
            connection: prepared.connection,
            consumedAt: now,
            owner: runtimeOwner)
        guard consumed else {
            throw DatabaseConfirmationError.alreadyConsumedOrUnknown
        }
        return try await operation(prepared.connection, plan)
    }

    private func prepare(_ plan: DatabaseDestructivePlan) async throws
        -> DatabasePreparedMutation
    {
        try Self.validate(plan)
        guard
            let connection = try await metadataStore.connection(
                id: plan.request.target.connectionID)
        else {
            throw DatabaseConfirmationError.connectionNotFound(plan.request.target.connectionID)
        }
        guard connection.productHint == plan.request.payload.product else {
            throw DatabaseConfirmationError.productMismatch(
                expected: connection.productHint,
                actual: plan.request.payload.product)
        }
        try Self.validateMutationPolicy(connection)
        try Self.validateConnectionDisplayFields(connection)
        let policy = DatabaseMutationPolicySnapshot(connection)
        let authorization = DatabaseMutationAuthorizationEnvelope(
            version: Self.tokenSchemaVersion,
            plan: plan,
            policy: policy)
        let authorizationData = try Self.encode(authorization)
        try Self.validateEncodedSize(
            authorizationData,
            name: "canonical mutation payload",
            maximum: Self.maximumCanonicalPayloadBytes)
        let executionDigest = keyedDigest(authorizationData, domain: "execution")
        let redactor = try await DatabaseSecretRedactor(
            store: secretStore,
            references: Self.secretReferences(for: connection))
        let redactedConnection = Self.redact(connection.identity, with: redactor)
        let redactedContext = Self.redact(
            Self.mutationContext(connection: connection, target: plan.request.target),
            with: redactor)
        let redactedTarget = Self.redact(plan.request.target, with: redactor)
        let redactedSelectedRecords = plan.request.selectedRecords.map {
            Self.redact($0, with: redactor)
        }
        let redactedPredicate = plan.request.predicate.map {
            Self.redact($0, with: redactor)
        }
        let redactedImpact = DatabaseMutationImpact(
            count: plan.impact.count,
            description: redactor.redact(plan.impact.description))
        let redactedRequest = DatabaseMutationPreview(
            product: plan.request.payload.product,
            kind: plan.request.payload.kind,
            command: redactor.redact(plan.request.payload.command),
            parameters: plan.request.payload.parameters.map {
                DatabaseMutationParameterPreview(
                    name: redactor.redact($0.name),
                    valueKind: Self.previewKind(of: $0.value))
            },
            body: plan.request.payload.body.map { redactor.redact($0) })
        let redactedWarnings = plan.warnings.map {
            Self.redact($0, with: redactor)
        }
        let effectSnapshot = DatabaseDestructiveEffectSnapshot(
            action: plan.action,
            connection: redactedConnection,
            context: redactedContext,
            target: redactedTarget,
            selectedRecords: redactedSelectedRecords,
            predicate: redactedPredicate,
            scope: plan.scope,
            impact: redactedImpact,
            transactionBehavior: plan.transactionBehavior,
            rollbackAvailability: plan.rollbackAvailability,
            executionMode: plan.executionMode)
        let requiredConfirmation = try Self.requiredConfirmation(
            plan: plan,
            connection: redactedConnection,
            target: redactedTarget)
        let display = DatabaseMutationDisplayEnvelope(
            effect: effectSnapshot,
            request: redactedRequest,
            warnings: redactedWarnings,
            requiredConfirmation: requiredConfirmation)
        let displayData = try Self.encode(display)
        try Self.validateEncodedSize(
            displayData,
            name: "mutation display payload",
            maximum: Self.maximumDisplayPayloadBytes)
        let displayDigest = keyedDigest(displayData, domain: "display")
        let effect = DatabaseDestructiveEffect(
            action: effectSnapshot.action,
            connection: effectSnapshot.connection,
            context: effectSnapshot.context,
            target: effectSnapshot.target,
            selectedRecords: effectSnapshot.selectedRecords,
            predicate: effectSnapshot.predicate,
            scope: effectSnapshot.scope,
            impact: effectSnapshot.impact,
            transactionBehavior: effectSnapshot.transactionBehavior,
            rollbackAvailability: effectSnapshot.rollbackAvailability,
            executionMode: effectSnapshot.executionMode,
            executionDigest: executionDigest,
            displayDigest: displayDigest)
        let receiptDigest = keyedDigest(
            try Self.encode(
                DatabaseConfirmationBinding(
                    executionDigest: executionDigest,
                    displayDigest: displayDigest)),
            domain: "receipt")
        return DatabasePreparedMutation(
            connection: connection,
            effect: effect,
            request: redactedRequest,
            warnings: redactedWarnings,
            requiredConfirmation: requiredConfirmation,
            executionDigest: executionDigest,
            displayDigest: displayDigest,
            receiptDigest: receiptDigest)
    }

    private func authenticate(_ token: DatabaseConfirmationToken) throws
        -> DatabaseConfirmationTokenPayload
    {
        guard token.rawValue.utf8.count <= Self.maximumTokenBytes else {
            throw DatabaseConfirmationError.malformedToken
        }
        let parts = token.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw DatabaseConfirmationError.malformedToken
        }
        let payloadPart = String(parts[0])
        let signaturePart = String(parts[1])
        guard let payloadData = Data(databaseBase64URL: payloadPart),
            let signature = Data(databaseBase64URL: signaturePart),
            payloadData.databaseBase64URLString() == payloadPart,
            signature.databaseBase64URLString() == signaturePart,
            signature.count == SHA256.byteCount
        else {
            throw DatabaseConfirmationError.malformedToken
        }
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                signature,
                authenticating: Self.domainSeparated(payloadData, domain: "token"),
                using: signingKey)
        else {
            throw DatabaseConfirmationError.invalidSignature
        }
        do {
            let payload = try Self.decoder().decode(
                DatabaseConfirmationTokenPayload.self,
                from: payloadData)
            guard try Self.encode(payload) == payloadData else {
                throw DatabaseConfirmationError.malformedToken
            }
            return payload
        } catch {
            throw DatabaseConfirmationError.malformedToken
        }
    }

    private func keyedDigest(_ data: Data, domain: String) -> String {
        Data(
            HMAC<SHA256>.authenticationCode(
                for: Self.domainSeparated(data, domain: domain),
                using: signingKey)
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}

private struct DatabaseMutationPolicySnapshot: Codable, Hashable, Sendable {
    let version: Int
    let id: DatabaseConnectionID
    let displayName: String
    let product: DatabaseProduct
    let location: DatabaseConnectionLocation
    let username: String?
    let namespaces: DatabaseNamespaceDefaults
    let deploymentMode: DatabaseDeploymentMode
    let authentication: DatabaseAuthentication
    let tls: DatabaseTLSConfiguration
    let tunnel: DatabaseTunnelDefinition?
    let limits: DatabaseConnectionLimits
    let readOnlyPolicy: DatabaseReadOnlyPolicy
    let productionPolicy: DatabaseProductionPolicy
    let environment: DatabaseEnvironmentMetadata
    let options: [DatabaseNonSecretOption]
    let updatedAt: Date

    init(_ connection: DatabaseConnectionDefinition) {
        version = connection.version
        id = connection.id
        displayName = connection.displayName
        product = connection.productHint
        location = connection.location
        username = connection.username
        namespaces = connection.namespaces
        deploymentMode = connection.deploymentMode
        authentication = connection.authentication
        tls = connection.tls
        tunnel = connection.tunnel
        limits = connection.limits
        readOnlyPolicy = connection.readOnlyPolicy
        productionPolicy = connection.productionPolicy
        environment = connection.environment
        options = connection.options
        updatedAt = connection.updatedAt
    }
}

private struct DatabaseMutationAuthorizationEnvelope: Codable, Hashable, Sendable {
    let version: Int
    let plan: DatabaseDestructivePlan
    let policy: DatabaseMutationPolicySnapshot
}

private struct DatabaseDestructiveEffectSnapshot: Codable, Hashable, Sendable {
    let action: DatabaseDestructiveAction
    let connection: DatabaseConnectionIdentity
    let context: DatabaseMutationContext
    let target: DatabaseTargetIdentifier
    let selectedRecords: [DatabaseRecordIdentity]
    let predicate: DatabaseFilter?
    let scope: DatabaseMutationScope
    let impact: DatabaseMutationImpact
    let transactionBehavior: DatabaseTransactionBehavior
    let rollbackAvailability: DatabaseRollbackAvailability
    let executionMode: DatabaseExecutionMode
}

private struct DatabaseMutationDisplayEnvelope: Codable, Hashable, Sendable {
    let effect: DatabaseDestructiveEffectSnapshot
    let request: DatabaseMutationPreview
    let warnings: [DatabaseWarning]
    let requiredConfirmation: DatabaseRequiredConfirmation
}

private struct DatabaseConfirmationBinding: Codable, Hashable, Sendable {
    let executionDigest: String
    let displayDigest: String
}

private struct DatabasePreparedMutation: Sendable {
    let connection: DatabaseConnectionDefinition
    let effect: DatabaseDestructiveEffect
    let request: DatabaseMutationPreview
    let warnings: [DatabaseWarning]
    let requiredConfirmation: DatabaseRequiredConfirmation
    let executionDigest: String
    let displayDigest: String
    let receiptDigest: String
}

private struct DatabaseConfirmationTokenPayload: Codable, Hashable, Sendable {
    let version: Int
    let audience: String
    let identifier: UUID
    let executionDigest: String
    let displayDigest: String
    let issuedAt: Date
    let expiresAt: Date
}

private struct DatabaseConfirmationInputBudget {
    var nodes = 0
    var bytes = 0

    mutating func addNode(depth: Int) throws {
        guard depth <= DatabaseConfirmationAuthority.maximumInputDepth else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "input depth",
                actual: depth,
                maximum: DatabaseConfirmationAuthority.maximumInputDepth)
        }
        nodes += 1
        guard nodes <= DatabaseConfirmationAuthority.maximumInputNodes else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "input nodes",
                actual: nodes,
                maximum: DatabaseConfirmationAuthority.maximumInputNodes)
        }
    }

    mutating func addBytes(_ count: Int) throws {
        let addition = bytes.addingReportingOverflow(count)
        guard !addition.overflow,
            addition.partialValue <= DatabaseConfirmationAuthority.maximumInputBytes
        else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "input bytes",
                actual: addition.overflow ? Int.max : addition.partialValue,
                maximum: DatabaseConfirmationAuthority.maximumInputBytes)
        }
        bytes = addition.partialValue
    }
}

extension DatabaseConfirmationAuthority {
    private static func domainSeparated(_ data: Data, domain: String) -> Data {
        var authenticated = Data("\(tokenAudience):\(domain)".utf8)
        authenticated.append(0)
        authenticated.append(data)
        return authenticated
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try encoder().encode(value)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func validate(_ plan: DatabaseDestructivePlan) throws {
        var budget = DatabaseConfirmationInputBudget()
        guard plan.request.version == DatabaseDestructiveRequest.schemaVersion else {
            throw DatabaseConfirmationError.invalidRequest(
                "Mutation request schema version is unsupported.")
        }
        try validatePayloadFamily(plan.request.payload)
        try validateText(
            plan.request.payload.command,
            name: "command",
            maximum: maximumCommandBytes,
            allowEmpty: false,
            budget: &budget)
        guard plan.request.payload.parameters.count <= maximumParameterCount else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "parameters",
                actual: plan.request.payload.parameters.count,
                maximum: maximumParameterCount)
        }
        var parameterNames = Set<String>()
        for parameter in plan.request.payload.parameters {
            try validateText(
                parameter.name,
                name: "parameter name",
                maximum: 512,
                allowEmpty: false,
                budget: &budget)
            guard parameterNames.insert(parameter.name).inserted else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Mutation parameter names must be unique.")
            }
            try validate(parameter.value, depth: 1, budget: &budget)
        }
        if let body = plan.request.payload.body {
            try validate(body, depth: 1, budget: &budget)
        }
        try validate(plan.request.target, budget: &budget)
        guard plan.request.selectedRecords.count <= maximumSelectedRecordCount else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "selected records",
                actual: plan.request.selectedRecords.count,
                maximum: maximumSelectedRecordCount)
        }
        guard Set(plan.request.selectedRecords).count == plan.request.selectedRecords.count else {
            throw DatabaseConfirmationError.invalidRequest(
                "Selected record identities must be unique.")
        }
        for record in plan.request.selectedRecords {
            try validate(record, budget: &budget)
        }
        if let predicate = plan.request.predicate {
            try validate(predicate, depth: 1, budget: &budget)
        }
        try validateText(
            plan.impact.description,
            name: "impact description",
            maximum: maximumImpactDescriptionBytes,
            allowEmpty: false,
            budget: &budget)
        guard plan.warnings.count <= maximumWarningCount else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "warnings",
                actual: plan.warnings.count,
                maximum: maximumWarningCount)
        }
        for warning in plan.warnings {
            try validateText(
                warning.code,
                name: "warning code",
                maximum: 256,
                allowEmpty: false,
                budget: &budget)
            try validateText(
                warning.message,
                name: "warning message",
                maximum: maximumWarningMessageBytes,
                allowEmpty: false,
                budget: &budget)
            if let target = warning.target {
                guard target.connectionID == plan.request.target.connectionID else {
                    throw DatabaseConfirmationError.invalidRequest(
                        "Warning targets must use the mutation connection.")
                }
                try validate(target, budget: &budget)
            }
        }
        switch plan.scope {
        case .singleRecord:
            guard plan.request.target.record != nil,
                plan.request.selectedRecords.isEmpty,
                plan.request.predicate == nil
            else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Single-record mutations require only one target record identity.")
            }
        case .selectedRecords:
            guard plan.request.target.record == nil,
                !plan.request.selectedRecords.isEmpty,
                plan.request.predicate == nil
            else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Selected-record mutations require only an explicit record selection.")
            }
        case .predicate:
            guard plan.request.target.record == nil,
                plan.request.selectedRecords.isEmpty,
                plan.request.predicate != nil
            else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Predicate mutations require only a predicate target.")
            }
        case .entireObject:
            guard plan.request.target.object != nil,
                plan.request.target.record == nil,
                plan.request.selectedRecords.isEmpty,
                plan.request.predicate == nil
            else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Whole-object mutations require only an object target.")
            }
        }
        if plan.action == .updateMany || plan.action == .deleteMany {
            guard
                plan.scope == .selectedRecords || plan.scope == .predicate
                    || plan.scope == .entireObject
            else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Bulk mutations require a selected-record, predicate, or whole-object scope.")
            }
        }
    }

    private static func validatePayloadFamily(_ payload: DatabaseMutationPayload) throws {
        let valid: Bool
        switch payload {
        case .administrative:
            valid = true
        case .relational:
            valid = payload.product.family == .relational || payload.product == .clickHouse
        case .keyspace:
            valid = payload.product.family == .keyValue
        case .document:
            valid = payload.product.family == .document
        case .search:
            valid = payload.product.family == .search
        case .analytical:
            valid = payload.product.family == .analytical
        }
        guard valid else {
            throw DatabaseConfirmationError.invalidRequest(
                "Mutation payload kind does not match the database product.")
        }
    }

    private static func validateMutationPolicy(_ connection: DatabaseConnectionDefinition) throws {
        if connection.readOnlyPolicy == .required {
            throw DatabaseConfirmationError.mutationProhibited(.connectionReadOnly)
        }
        if connection.environment.protection == .readOnly {
            throw DatabaseConfirmationError.mutationProhibited(.environmentReadOnly)
        }
        if connection.productionPolicy == .prohibitMutations {
            throw DatabaseConfirmationError.mutationProhibited(.productionPolicy)
        }
    }

    private static func validateConnectionDisplayFields(
        _ connection: DatabaseConnectionDefinition
    ) throws {
        var budget = DatabaseConfirmationInputBudget()
        try validateText(
            connection.displayName,
            name: "connection display name",
            maximum: 4_096,
            allowEmpty: false,
            budget: &budget)
        try validateText(
            connection.environment.label,
            name: "environment label",
            maximum: 4_096,
            allowEmpty: false,
            budget: &budget)
    }

    private static func validate(
        _ target: DatabaseTargetIdentifier,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        try budget.addNode(depth: 1)
        if let object = target.object {
            guard !object.path.isEmpty else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Object targets require a path.")
            }
            guard object.path.count <= maximumPathSegmentCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "object path segments",
                    actual: object.path.count,
                    maximum: maximumPathSegmentCount)
            }
            for segment in object.path {
                try validateText(
                    segment,
                    name: "object path segment",
                    maximum: 4_096,
                    allowEmpty: false,
                    budget: &budget)
            }
            if let nativeIdentifier = object.nativeIdentifier {
                try validateText(
                    nativeIdentifier,
                    name: "native identifier",
                    maximum: 4_096,
                    allowEmpty: false,
                    budget: &budget)
            }
        }
        if let record = target.record {
            try validate(record, budget: &budget)
        }
    }

    private static func validate(
        _ record: DatabaseRecordIdentity,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        try budget.addNode(depth: 1)
        guard !record.components.isEmpty else {
            throw DatabaseConfirmationError.invalidRequest(
                "Record targets require identity components.")
        }
        guard record.components.count <= 256,
            record.concurrencyTokens.count <= 256
        else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "record identity components",
                actual: max(record.components.count, record.concurrencyTokens.count),
                maximum: 256)
        }
        for component in record.components + record.concurrencyTokens {
            try validateText(
                component.name,
                name: "identity component name",
                maximum: 512,
                allowEmpty: false,
                budget: &budget)
            try validate(component.value, depth: 1, budget: &budget)
        }
    }

    private static func validate(
        _ filter: DatabaseFilter,
        depth: Int,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        try budget.addNode(depth: depth)
        switch filter {
        case let .predicate(predicate):
            guard !predicate.field.segments.isEmpty else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Filter predicates require a field path.")
            }
            guard predicate.field.segments.count <= maximumPathSegmentCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "filter path segments",
                    actual: predicate.field.segments.count,
                    maximum: maximumPathSegmentCount)
            }
            for segment in predicate.field.segments {
                try validateText(
                    segment,
                    name: "filter field segment",
                    maximum: 4_096,
                    allowEmpty: false,
                    budget: &budget)
            }
            guard predicate.values.count <= maximumCollectionCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "filter values",
                    actual: predicate.values.count,
                    maximum: maximumCollectionCount)
            }
            for value in predicate.values {
                try validate(value, depth: depth + 1, budget: &budget)
            }
        case let .all(children), let .any(children):
            guard !children.isEmpty else {
                throw DatabaseConfirmationError.invalidRequest(
                    "Compound filters require at least one child.")
            }
            guard children.count <= maximumCollectionCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "filter children",
                    actual: children.count,
                    maximum: maximumCollectionCount)
            }
            for child in children {
                try validate(child, depth: depth + 1, budget: &budget)
            }
        case let .not(child):
            try validate(child, depth: depth + 1, budget: &budget)
        }
    }

    private static func validate(
        _ value: DatabaseValue,
        depth: Int,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        try budget.addNode(depth: depth)
        switch value {
        case .missing, .null, .boolean, .signedInteger, .unsignedInteger, .floatingPoint, .uuid:
            break
        case let .decimal(value):
            try validateText(
                value.rawValue,
                name: "decimal value",
                maximum: maximumTextBytes,
                allowEmpty: false,
                budget: &budget)
        case let .string(value):
            try validateText(
                value,
                name: "string value",
                maximum: maximumTextBytes,
                allowEmpty: true,
                budget: &budget)
        case let .binary(value):
            try budget.addBytes(value.availableBytes.count)
            switch value {
            case let .complete(_, mediaType, digest), let .preview(_, _, mediaType, digest):
                try validateOptionalText(mediaType, name: "binary media type", budget: &budget)
                try validateOptionalText(digest, name: "binary digest", budget: &budget)
            }
        case let .date(value):
            try validateTextValue(value.text, name: "date text", budget: &budget)
            try validateOptionalText(
                value.calendarIdentifier,
                name: "calendar identifier",
                budget: &budget)
        case let .time(value):
            try validateTextValue(value.text, name: "time text", budget: &budget)
        case let .timestamp(value):
            try validateTextValue(value.text, name: "timestamp text", budget: &budget)
            try validateOptionalText(
                value.timeZoneIdentifier,
                name: "time zone identifier",
                budget: &budget)
        case let .array(values):
            guard values.count <= maximumCollectionCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "array values",
                    actual: values.count,
                    maximum: maximumCollectionCount)
            }
            for child in values {
                try validate(child, depth: depth + 1, budget: &budget)
            }
        case let .object(fields):
            guard fields.count <= maximumCollectionCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "object fields",
                    actual: fields.count,
                    maximum: maximumCollectionCount)
            }
            for field in fields {
                try validateText(
                    field.name,
                    name: "object field name",
                    maximum: 4_096,
                    allowEmpty: false,
                    budget: &budget)
                try validate(field.value, depth: depth + 1, budget: &budget)
            }
        case let .productSpecific(value):
            try validateTextValue(value.typeName, name: "product type name", budget: &budget)
            try validateOptionalText(
                value.textRepresentation,
                name: "product text representation",
                budget: &budget)
            if let binary = value.binaryRepresentation {
                try budget.addBytes(binary.count)
            }
            guard value.attributes.count <= maximumCollectionCount else {
                throw DatabaseConfirmationError.limitExceeded(
                    name: "product attributes",
                    actual: value.attributes.count,
                    maximum: maximumCollectionCount)
            }
            for attribute in value.attributes {
                try validateTextValue(attribute.name, name: "attribute name", budget: &budget)
                try validateTextValue(attribute.value, name: "attribute value", budget: &budget)
            }
        }
    }

    private static func validateTextValue(
        _ value: String,
        name: String,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        try validateText(
            value,
            name: name,
            maximum: maximumTextBytes,
            allowEmpty: true,
            budget: &budget)
    }

    private static func validateOptionalText(
        _ value: String?,
        name: String,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        if let value {
            try validateTextValue(value, name: name, budget: &budget)
        }
    }

    private static func validateText(
        _ value: String,
        name: String,
        maximum: Int,
        allowEmpty: Bool,
        budget: inout DatabaseConfirmationInputBudget
    ) throws {
        let count = value.utf8.count
        guard allowEmpty || count > 0 else {
            throw DatabaseConfirmationError.invalidRequest("\(name) must not be empty.")
        }
        guard count <= maximum else {
            throw DatabaseConfirmationError.limitExceeded(
                name: name,
                actual: count,
                maximum: maximum)
        }
        try budget.addBytes(count)
    }

    private static func validateEncodedSize(_ data: Data, name: String, maximum: Int) throws {
        guard data.count <= maximum else {
            throw DatabaseConfirmationError.limitExceeded(
                name: name,
                actual: data.count,
                maximum: maximum)
        }
    }

    private static func secretReferences(
        for connection: DatabaseConnectionDefinition
    ) -> [DatabaseSecretReference] {
        var references = connection.authentication.secretReferences
        if let clientPrivateKey = connection.tls.clientPrivateKey {
            references.append(clientPrivateKey)
        }
        return references
    }

    private static func redact(
        _ identity: DatabaseConnectionIdentity,
        with redactor: DatabaseSecretRedactor
    ) -> DatabaseConnectionIdentity {
        DatabaseConnectionIdentity(
            id: identity.id,
            displayName: redactor.redact(identity.displayName),
            productHint: identity.productHint,
            environment: DatabaseEnvironmentMetadata(
                kind: identity.environment.kind,
                label: redactor.redact(identity.environment.label),
                protection: identity.environment.protection))
    }

    private static func redact(
        _ context: DatabaseMutationContext,
        with redactor: DatabaseSecretRedactor
    ) -> DatabaseMutationContext {
        DatabaseMutationContext(
            kind: context.kind,
            value: redactor.redact(context.value),
            catalog: context.catalog.map { redactor.redact($0) },
            schema: context.schema.map { redactor.redact($0) })
    }

    private static func redact(
        _ target: DatabaseTargetIdentifier,
        with redactor: DatabaseSecretRedactor
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: target.connectionID,
            object: target.object.map {
                DatabaseObjectIdentifier(
                    kind: $0.kind,
                    path: $0.path.map { redactor.redact($0) },
                    nativeIdentifier: $0.nativeIdentifier.map { redactor.redact($0) })
            },
            record: target.record.map { redact($0, with: redactor) })
    }

    private static func redact(
        _ record: DatabaseRecordIdentity,
        with redactor: DatabaseSecretRedactor
    ) -> DatabaseRecordIdentity {
        DatabaseRecordIdentity(
            kind: record.kind,
            components: record.components.map {
                DatabaseIdentityComponent(
                    name: redactor.redact($0.name),
                    value: redactor.redact($0.value))
            },
            concurrencyTokens: record.concurrencyTokens.map {
                DatabaseIdentityComponent(
                    name: redactor.redact($0.name),
                    value: redactor.redact($0.value))
            })
    }

    private static func redact(
        _ filter: DatabaseFilter,
        with redactor: DatabaseSecretRedactor
    ) -> DatabaseFilter {
        switch filter {
        case let .predicate(predicate):
            return .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath(
                        predicate.field.segments.map { redactor.redact($0) }),
                    operation: predicate.operation,
                    values: predicate.values.map { redactor.redact($0) },
                    caseSensitivity: predicate.caseSensitivity))
        case let .all(children):
            return .all(children.map { redact($0, with: redactor) })
        case let .any(children):
            return .any(children.map { redact($0, with: redactor) })
        case let .not(child):
            return .not(redact(child, with: redactor))
        }
    }

    private static func redact(
        _ warning: DatabaseWarning,
        with redactor: DatabaseSecretRedactor
    ) -> DatabaseWarning {
        DatabaseWarning(
            code: redactor.redact(warning.code),
            message: redactor.redact(warning.message),
            severity: warning.severity,
            target: warning.target.map { redact($0, with: redactor) })
    }

    private static func previewKind(of value: DatabaseValue) -> DatabaseValuePreviewKind {
        switch value {
        case .missing:
            .missing
        case .null:
            .null
        case .boolean:
            .boolean
        case .signedInteger:
            .signedInteger
        case .unsignedInteger:
            .unsignedInteger
        case .decimal:
            .decimal
        case .floatingPoint:
            .floatingPoint
        case .string:
            .string
        case .binary:
            .binary
        case .date:
            .date
        case .time:
            .time
        case .timestamp:
            .timestamp
        case .uuid:
            .uuid
        case .array:
            .array
        case .object:
            .object
        case .productSpecific:
            .productSpecific
        }
    }

    private static func mutationContext(
        connection: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier
    ) -> DatabaseMutationContext {
        switch connection.productHint {
        case .postgresql:
            relationalMutationContext(connection: connection, target: target)
        case .mysql, .mariaDB, .mongoDB, .clickHouse:
            databaseMutationContext(connection: connection, target: target)
        case .sqlite:
            sqliteMutationContext(connection: connection, target: target)
        case .redis, .valkey:
            DatabaseMutationContext(
                kind: .logicalDatabase,
                value: connection.namespaces.logicalDatabase
                    ?? target.object.flatMap {
                        $0.kind == .keyspace ? $0.path.first : nil
                    }
                    ?? "0")
        case .elasticsearch, .openSearch:
            DatabaseMutationContext(kind: .cluster, value: connection.displayName)
        }
    }

    private static func relationalMutationContext(
        connection: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier
    ) -> DatabaseMutationContext {
        let namespaces = connection.namespaces
        guard let object = target.object else {
            return DatabaseMutationContext(
                kind: .database,
                value: namespaces.database ?? namespaces.catalog ?? connection.displayName,
                catalog: namespaces.catalog,
                schema: namespaces.schema)
        }
        let path = object.path
        var catalog = namespaces.catalog
        var database = namespaces.database ?? namespaces.catalog
        var schema = namespaces.schema
        switch object.kind {
        case .catalog:
            catalog = path.last ?? catalog
        case .database:
            if path.count > 1 {
                catalog = path[path.count - 2]
            }
            database = path.last ?? database
        case .schema:
            if path.count > 2 {
                catalog = path[path.count - 3]
            }
            if path.count > 1 {
                database = path[path.count - 2]
            }
            schema = path.last ?? schema
        default:
            if path.count >= 4 {
                catalog = path[0]
                database = path[1]
                schema = path[2]
            } else if path.count >= 3 {
                database = path[0]
                schema = path[1]
            } else if path.count >= 2 {
                schema = path[0]
            }
        }
        return DatabaseMutationContext(
            kind: .database,
            value: database ?? catalog ?? connection.displayName,
            catalog: catalog,
            schema: schema)
    }

    private static func databaseMutationContext(
        connection: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier
    ) -> DatabaseMutationContext {
        let object = target.object
        let pathDatabase: String? =
            if object?.kind == .database {
                object?.path.last
            } else if let path = object?.path, path.count >= 2 {
                path.first
            } else {
                nil
            }
        return DatabaseMutationContext(
            kind: .database,
            value: pathDatabase ?? connection.namespaces.database
                ?? connection.namespaces.catalog ?? connection.displayName,
            catalog: connection.namespaces.catalog,
            schema: connection.namespaces.schema)
    }

    private static func sqliteMutationContext(
        connection: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier
    ) -> DatabaseMutationContext {
        let object = target.object
        let path = object?.path ?? []
        let pathDatabase: String? = object?.kind == .database ? path.last : nil
        let pathSchema: String? =
            if object?.kind == .schema {
                path.last
            } else if path.count >= 2 {
                path.first
            } else {
                nil
            }
        return DatabaseMutationContext(
            kind: .database,
            value: pathDatabase ?? connection.namespaces.database
                ?? connection.displayName,
            catalog: connection.namespaces.catalog,
            schema: pathSchema ?? connection.namespaces.schema ?? "main")
    }

    private static func requiredConfirmation(
        plan: DatabaseDestructivePlan,
        connection: DatabaseConnectionIdentity,
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseRequiredConfirmation {
        let targetText = renderTarget(target)
        let strongestActions: Set<DatabaseDestructiveAction> = [
            .truncate,
            .dropObject,
            .schemaChange,
            .permissionChange,
            .terminateSession,
            .maintenance,
            .reindex,
            .asynchronousMutation,
        ]
        let strongest =
            connection.environment.kind == .production
            || connection.environment.protection == .confirmationRequired
            || plan.scope == .entireObject
            || plan.transactionBehavior != .transactional
            || plan.rollbackAvailability != .available
            || plan.executionMode == .asynchronous
            || strongestActions.contains(plan.action)
        let confirmation: DatabaseRequiredConfirmation
        if strongest {
            let connectionText = lengthPrefixed(connection.displayName)
            confirmation = DatabaseRequiredConfirmation(
                strength: .connectionAndTarget,
                text: "connection[\(connectionText)] target[\(targetText)]")
        } else if plan.scope == .predicate || plan.scope == .selectedRecords
            || plan.action == .deleteMany || plan.action == .updateMany
        {
            confirmation = DatabaseRequiredConfirmation(strength: .target, text: targetText)
        } else {
            confirmation = DatabaseRequiredConfirmation(strength: .explicit, text: "confirm")
        }
        guard confirmation.text.utf8.count <= maximumConfirmationTextBytes else {
            throw DatabaseConfirmationError.limitExceeded(
                name: "confirmation text",
                actual: confirmation.text.utf8.count,
                maximum: maximumConfirmationTextBytes)
        }
        return confirmation
    }

    private static func renderTarget(_ target: DatabaseTargetIdentifier) -> String {
        guard let object = target.object else { return "connection" }
        let path = object.path.map(lengthPrefixed).joined(separator: "|")
        return "\(object.kind.rawValue)[\(path)]"
    }

    private static func lengthPrefixed(_ value: String) -> String {
        let rendered = printableConfirmationIdentifier(value)
        return "\(rendered.utf8.count):\(rendered)"
    }

    private static func printableConfirmationIdentifier(_ value: String) -> String {
        var rendered = ""
        rendered.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            let requiresEscaping =
                switch scalar.value {
                case 0x3A, 0x5B, 0x5C, 0x5D, 0x7C:
                    true
                default:
                    switch scalar.properties.generalCategory {
                    case .control, .format, .lineSeparator, .paragraphSeparator:
                        true
                    default:
                        false
                    }
                }
            if requiresEscaping {
                let hexadecimal = String(scalar.value, radix: 16, uppercase: true)
                let padding = String(repeating: "0", count: max(0, 4 - hexadecimal.count))
                rendered.append("\\u{\(padding)\(hexadecimal)}")
            } else {
                rendered.unicodeScalars.append(scalar)
            }
        }
        return rendered
    }

    private static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let firstBytes = Array(first.utf8)
        let secondBytes = Array(second.utf8)
        guard firstBytes.count == secondBytes.count else { return false }
        var difference: UInt8 = 0
        for index in firstBytes.indices {
            difference |= firstBytes[index] ^ secondBytes[index]
        }
        return difference == 0
    }
}

extension Data {
    fileprivate init?(databaseBase64URL value: String) {
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

    fileprivate func databaseBase64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
