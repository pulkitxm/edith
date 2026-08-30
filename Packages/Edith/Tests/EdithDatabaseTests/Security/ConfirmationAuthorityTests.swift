import Foundation
import Testing

@testable import EdithDatabase

final class DatabaseConfirmationTestClock: @unchecked Sendable {
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

actor DatabaseConfirmationExecutionProbe {
    private var invocations = 0

    func invoke(_ result: String = "executed") -> String {
        invocations += 1
        return result
    }

    func count() -> Int {
        invocations
    }
}

enum DatabaseConfirmationOperationError: Error, Equatable {
    case failed
}

enum DatabaseConfirmationExecutionAttempt: Equatable, Sendable {
    case success(String)
    case confirmationFailure(DatabaseConfirmationError)
    case unexpectedFailure
}

enum DatabaseConfirmationFixtures {
    static let signingKey = Data((0..<32).map(UInt8.init))
    static let passwordReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "60DD737F-A9DA-478C-B89D-35E056820C15")!,
        purpose: .password)
    static let privateKeyReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "821428CF-2E6C-46A9-9A11-985BF574ABEA")!,
        purpose: .clientPrivateKey)

    static func connection(
        id: DatabaseConnectionID = DatabaseConnectionFixtures.connectionID,
        name: String = "Local orders",
        product: DatabaseProduct = .postgresql,
        environment: DatabaseEnvironmentKind = .development,
        environmentLabel: String = "development",
        protection: DatabaseEnvironmentProtection = .standard,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled,
        productionPolicy: DatabaseProductionPolicy = .standard,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        privateKey: DatabaseSecretReference? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 200)
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: id,
            displayName: name,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(5_432))
            ]),
            username: "edith",
            namespaces: DatabaseNamespaceDefaults(schema: "public", database: "edith_lab"),
            deploymentMode: .standalone,
            authentication: authentication,
            tls: DatabaseTLSConfiguration(
                mode: privateKey == nil ? .disabled : .required,
                verification: privateKey == nil ? .none : .full,
                clientPrivateKey: privateKey),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: environment,
                label: environmentLabel,
                protection: protection),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: updatedAt)
    }

    static func target(
        connectionID: DatabaseConnectionID = DatabaseConnectionFixtures.connectionID,
        path: [String] = ["orders", "public", "invoices"],
        includeRecord: Bool = true,
        recordValue: DatabaseValue = .signedInteger(42)
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .table, path: path),
            record: includeRecord
                ? DatabaseRecordIdentity(
                    kind: .primaryKey,
                    components: [
                        DatabaseIdentityComponent(name: "id", value: recordValue)
                    ],
                    concurrencyTokens: [
                        DatabaseIdentityComponent(name: "version", value: .signedInteger(7))
                    ])
                : nil)
    }

    static func predicate(_ value: DatabaseValue = .string("cancelled")) -> DatabaseFilter {
        .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("state"),
                operation: .equal,
                values: [value]))
    }

    static func payload(
        product: DatabaseProduct = .postgresql,
        command: String = "DELETE FROM invoices WHERE state = $1 AND tenant_id = $2",
        firstValue: DatabaseValue = .string("cancelled"),
        secondValue: DatabaseValue = .signedInteger(9),
        body: DatabaseValue? = nil
    ) -> DatabaseMutationPayload {
        let parameters = [
            DatabaseMutationParameter(name: "state", value: firstValue),
            DatabaseMutationParameter(name: "tenant", value: secondValue),
        ]
        if let body {
            return .administrative(
                product: product,
                command: command,
                parameters: parameters,
                body: body)
        }
        return .relational(product: product, statement: command, parameters: parameters)
    }

    static func plan(
        target: DatabaseTargetIdentifier = target(includeRecord: false),
        selectedRecords: [DatabaseRecordIdentity] = [],
        predicate: DatabaseFilter? = predicate(),
        payload: DatabaseMutationPayload = payload(),
        action: DatabaseDestructiveAction = .deleteMany,
        scope: DatabaseMutationScope = .predicate,
        count: DatabaseCountMetadata = DatabaseCountMetadata(value: 40, accuracy: .estimated),
        impact: String = "About 40 matching rows",
        transactionBehavior: DatabaseTransactionBehavior = .transactional,
        rollbackAvailability: DatabaseRollbackAvailability = .available,
        executionMode: DatabaseExecutionMode = .synchronous,
        warnings: [DatabaseWarning] = []
    ) -> DatabaseDestructivePlan {
        DatabaseDestructivePlan(
            request: DatabaseDestructiveRequest(
                target: target,
                selectedRecords: selectedRecords,
                predicate: predicate,
                payload: payload),
            action: action,
            scope: scope,
            impact: DatabaseMutationImpact(count: count, description: impact),
            transactionBehavior: transactionBehavior,
            rollbackAvailability: rollbackAvailability,
            executionMode: executionMode,
            warnings: warnings)
    }

    static func authority(
        path: String,
        clock: DatabaseConfirmationTestClock,
        secretStore: any DatabaseSecretStore,
        signingKey: Data = signingKey
    ) async throws -> DatabaseConfirmationAuthority {
        let metadataStore = try SQLiteDatabaseMetadataStore(path: path)
        let runtimeOwner =
            if let owner = try await metadataStore.runtimeOwner(), owner.isReady {
                owner.token
            } else {
                try await DatabaseRuntimeOwnerFactory.claimReadyOwner(
                    from: metadataStore,
                    claimedAt: clock.now()
                ).owner.token
            }
        return try DatabaseConfirmationAuthority(
            signingKey: signingKey,
            metadataStore: metadataStore,
            secretStore: secretStore,
            runtimeOwner: runtimeOwner,
            currentDate: { clock.now() })
    }

    static func execute(
        authority: DatabaseConfirmationAuthority,
        token: DatabaseConfirmationToken,
        plan: DatabaseDestructivePlan,
        confirmationText: String,
        probe: DatabaseConfirmationExecutionProbe
    ) async -> DatabaseConfirmationExecutionAttempt {
        do {
            let result = try await authority.authorizeAndExecute(
                token: token,
                plan: plan,
                confirmationText: confirmationText
            ) { _, _ in
                await probe.invoke()
            }
            return .success(result)
        } catch let error as DatabaseConfirmationError {
            return .confirmationFailure(error)
        } catch {
            return .unexpectedFailure
        }
    }
}

@Suite struct DatabaseConfirmationAuthorityTests {
    @Test func factorySharesOneDedicatedSigningKeyAcrossAuthorities() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretStore = try InMemoryDatabaseSecretStore()
        let firstMetadata = try SQLiteDatabaseMetadataStore(path: path)
        let secondMetadata = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabaseConfirmationFixtures.connection()
        try await firstMetadata.seedConnection(connection)
        let runtimeOwner = try await firstMetadata.claimRuntimeOwner(
            claimedAt: Date(timeIntervalSince1970: 1)
        ).owner.token

        async let first = DatabaseConfirmationAuthority.create(
            secretStore: secretStore,
            metadataStore: firstMetadata,
            runtimeOwner: runtimeOwner)
        async let second = DatabaseConfirmationAuthority.create(
            secretStore: secretStore,
            metadataStore: secondMetadata,
            runtimeOwner: runtimeOwner)
        let (issuer, executor) = try await (first, second)
        let plan = DatabaseConfirmationFixtures.plan()
        let preview = try await issuer.issuePreview(for: plan)
        let result = try await executor.authorizeAndExecute(
            token: preview.token,
            plan: plan,
            confirmationText: preview.requiredConfirmation.text
        ) { snapshot, executedPlan in
            #expect(snapshot == connection)
            #expect(executedPlan == plan)
            return "executed"
        }

        #expect(result == "executed")
        #expect(
            try await secretStore.read(DatabaseConfirmationAuthority.signingKeyReference).count
                == DatabaseConfirmationAuthority.signingKeyByteRange.lowerBound)
        #expect(
            DatabaseConfirmationAuthority.signingKeyReference.purpose == .confirmationSigningKey)
    }

    @Test func previewIsCanonicalAuthoritativeAndFullyRedacted() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = DatabaseConfirmationTestClock(Date(timeIntervalSince1970: 1_000))
        let password = "super-secret-password"
        let privateKey = "private-key-material"
        let hiddenParameter = "customer-private-note"
        let secretStore = try InMemoryDatabaseSecretStore(
            initialValues: [
                DatabaseConfirmationFixtures.passwordReference: Data(password.utf8),
                DatabaseConfirmationFixtures.privateKeyReference: Data(privateKey.utf8),
            ])
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        let connection = try DatabaseConfirmationFixtures.connection(
            name: "Orders \(password)",
            environment: .production,
            environmentLabel: "production \(privateKey)",
            protection: .confirmationRequired,
            productionPolicy: .requireMutationPreview,
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [DatabaseConfirmationFixtures.passwordReference]),
            privateKey: DatabaseConfirmationFixtures.privateKeyReference)
        try await metadata.seedConnection(connection)
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let target = DatabaseConfirmationFixtures.target(
            path: ["orders", password, "invoices"],
            recordValue: .string(privateKey))
        let payload = DatabaseConfirmationFixtures.payload(
            command: "DELETE \(password)",
            firstValue: .string(privateKey),
            secondValue: .string(hiddenParameter),
            body: .object([
                DatabaseObjectField(name: password, value: .string(privateKey))
            ]))
        let warning = DatabaseWarning(
            code: "unsafe-\(password)",
            message: "contains \(privateKey)",
            severity: .high,
            target: target)
        let plan = DatabaseConfirmationFixtures.plan(
            target: target,
            predicate: nil,
            payload: payload,
            action: .update,
            scope: .singleRecord,
            impact: "removes \(password)",
            warnings: [warning])

        let preview = try await authority.issuePreview(for: plan)
        let encoded = try JSONEncoder().encode(preview)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains(password))
        #expect(!text.contains(privateKey))
        #expect(!text.contains(hiddenParameter))
        #expect(text.contains(DatabaseSecretRedactor.defaultReplacement))
        #expect(preview.effect.connection.id == connection.id)
        #expect(preview.effect.connection.productHint == connection.productHint)
        #expect(preview.requiredConfirmation.strength == .connectionAndTarget)
        #expect(!preview.token.rawValue.contains("DELETE"))
    }

    @Test func executionDigestBindsCanonicalPlanSurfaces() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = DatabaseConfirmationTestClock(Date(timeIntervalSince1970: 2_000))
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        try await metadata.seedConnection(try DatabaseConfirmationFixtures.connection())
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let warning = DatabaseWarning(code: "bulk", message: "review", severity: .caution)
        let body = DatabaseValue.object([
            DatabaseObjectField(name: "reason", value: .string("expired"))
        ])
        let baseline = DatabaseConfirmationFixtures.plan(
            payload: DatabaseConfirmationFixtures.payload(body: body),
            warnings: [warning])
        let preview = try await authority.issuePreview(for: baseline)
        let changedTarget = DatabaseConfirmationFixtures.target(
            path: ["orders", "public", "other"],
            includeRecord: false)
        let variants = [
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(command: "DELETE FROM other"),
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(
                    firstValue: .string("active"),
                    body: body),
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(
                    body: .object([
                        DatabaseObjectField(name: "reason", value: .string("changed"))
                    ])),
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                predicate: DatabaseConfirmationFixtures.predicate(.string("active")),
                payload: DatabaseConfirmationFixtures.payload(body: body),
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                target: changedTarget,
                payload: DatabaseConfirmationFixtures.payload(body: body),
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(body: body),
                action: .updateMany,
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(body: body),
                impact: "About 41 matching rows",
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(body: body),
                transactionBehavior: .nontransactional,
                warnings: [warning]),
            DatabaseConfirmationFixtures.plan(
                payload: DatabaseConfirmationFixtures.payload(body: body),
                warnings: [DatabaseWarning(code: "bulk", message: "changed", severity: .high)]),
        ]
        let probe = DatabaseConfirmationExecutionProbe()

        for variant in variants {
            await #expect(throws: DatabaseConfirmationError.effectMismatch) {
                try await authority.authorizeAndExecute(
                    token: preview.token,
                    plan: variant,
                    confirmationText: preview.requiredConfirmation.text
                ) { _, _ in
                    await probe.invoke()
                }
            }
        }
        #expect(await probe.count() == 0)
        let result = try await authority.authorizeAndExecute(
            token: preview.token,
            plan: baseline,
            confirmationText: preview.requiredConfirmation.text
        ) { _, _ in
            await probe.invoke()
        }
        #expect(result == "executed")
        #expect(await probe.count() == 1)
    }

    @Test func authoritativeMetadataAndMutationPoliciesAreRechecked() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = DatabaseConfirmationTestClock(Date(timeIntervalSince1970: 3_000))
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let plan = DatabaseConfirmationFixtures.plan()

        await #expect(
            throws: DatabaseConfirmationError.connectionNotFound(
                DatabaseConnectionFixtures.connectionID)
        ) {
            try await authority.issuePreview(for: plan)
        }
        let allowed = try DatabaseConfirmationFixtures.connection()
        try await metadata.seedConnection(allowed)
        let preview = try await authority.issuePreview(for: plan)
        let changed = try DatabaseConfirmationFixtures.connection(
            name: "Changed identity",
            updatedAt: Date(timeIntervalSince1970: 201))
        try await metadata.seedConnection(changed)
        let probe = DatabaseConfirmationExecutionProbe()
        await #expect(throws: DatabaseConfirmationError.effectMismatch) {
            try await authority.authorizeAndExecute(
                token: preview.token,
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in
                await probe.invoke()
            }
        }
        try await metadata.seedConnection(allowed)
        _ = try await authority.authorizeAndExecute(
            token: preview.token,
            plan: plan,
            confirmationText: preview.requiredConfirmation.text
        ) { _, _ in
            await probe.invoke()
        }
        #expect(await probe.count() == 1)

        for (connection, error) in [
            (
                try DatabaseConfirmationFixtures.connection(readOnlyPolicy: .required),
                DatabaseConfirmationError.mutationProhibited(.connectionReadOnly)
            ),
            (
                try DatabaseConfirmationFixtures.connection(protection: .readOnly),
                DatabaseConfirmationError.mutationProhibited(.environmentReadOnly)
            ),
            (
                try DatabaseConfirmationFixtures.connection(
                    productionPolicy: .prohibitMutations),
                DatabaseConfirmationError.mutationProhibited(.productionPolicy)
            ),
        ] {
            try await metadata.seedConnection(connection)
            await #expect(throws: error) {
                try await authority.issuePreview(for: plan)
            }
        }
        try await metadata.seedConnection(
            try DatabaseConfirmationFixtures.connection(product: .mysql))
        await #expect(
            throws: DatabaseConfirmationError.productMismatch(
                expected: .mysql,
                actual: .postgresql)
        ) {
            try await authority.issuePreview(for: plan)
        }
    }

    @Test func validatesScopeAndDerivesConfirmationStrength() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = DatabaseConfirmationTestClock(Date(timeIntervalSince1970: 4_000))
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        try await metadata.seedConnection(try DatabaseConfirmationFixtures.connection())
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)

        let single = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(),
            predicate: nil,
            action: .update,
            scope: .singleRecord)
        let singlePreview = try await authority.issuePreview(for: single)
        #expect(singlePreview.requiredConfirmation.strength == .explicit)

        let predicate = DatabaseConfirmationFixtures.plan()
        let predicatePreview = try await authority.issuePreview(for: predicate)
        #expect(predicatePreview.requiredConfirmation.strength == .target)

        let selectedIdentity = try #require(DatabaseConfirmationFixtures.target().record)
        let selected = DatabaseConfirmationFixtures.plan(
            selectedRecords: [selectedIdentity],
            predicate: nil,
            action: .updateMany,
            scope: .selectedRecords)
        let selectedPreview = try await authority.issuePreview(for: selected)
        #expect(selectedPreview.effect.selectedRecords == [selectedIdentity])
        #expect(selectedPreview.requiredConfirmation.strength == .target)

        let wholeObject = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(includeRecord: false),
            predicate: nil,
            action: .deleteMany,
            scope: .entireObject)
        let wholePreview = try await authority.issuePreview(for: wholeObject)
        #expect(wholePreview.requiredConfirmation.strength == .connectionAndTarget)

        let nontransactional = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(),
            predicate: nil,
            action: .update,
            scope: .singleRecord,
            transactionBehavior: .nontransactional)
        let nontransactionalPreview = try await authority.issuePreview(for: nontransactional)
        #expect(nontransactionalPreview.requiredConfirmation.strength == .connectionAndTarget)

        let missingRecord = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(includeRecord: false),
            predicate: nil,
            action: .update,
            scope: .singleRecord)
        await #expect(
            throws: DatabaseConfirmationError.invalidRequest(
                "Single-record mutations require only one target record identity.")
        ) {
            try await authority.issuePreview(for: missingRecord)
        }
        let missingPredicate = DatabaseConfirmationFixtures.plan(predicate: nil)
        await #expect(
            throws: DatabaseConfirmationError.invalidRequest(
                "Predicate mutations require only a predicate target.")
        ) {
            try await authority.issuePreview(for: missingPredicate)
        }
        let emptyPredicate = DatabaseConfirmationFixtures.plan(predicate: .all([]))
        await #expect(
            throws: DatabaseConfirmationError.invalidRequest(
                "Compound filters require at least one child.")
        ) {
            try await authority.issuePreview(for: emptyPredicate)
        }
        let recordOnWholeObject = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(),
            predicate: nil,
            scope: .entireObject)
        await #expect(
            throws: DatabaseConfirmationError.invalidRequest(
                "Whole-object mutations require only an object target.")
        ) {
            try await authority.issuePreview(for: recordOnWholeObject)
        }
    }

    @Test func confirmationTargetEncodingCannotCollide() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = DatabaseConfirmationTestClock(Date(timeIntervalSince1970: 5_000))
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        try await metadata.seedConnection(
            try DatabaseConfirmationFixtures.connection(
                name: "prod/name",
                environment: .production,
                protection: .confirmationRequired))
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let firstPlan = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(
                path: ["schema.table"],
                includeRecord: false),
            predicate: nil,
            action: .dropObject,
            scope: .entireObject)
        let secondPlan = DatabaseConfirmationFixtures.plan(
            target: DatabaseConfirmationFixtures.target(
                path: ["schema", "table"],
                includeRecord: false),
            predicate: nil,
            action: .dropObject,
            scope: .entireObject)
        let first = try await authority.issuePreview(for: firstPlan)
        let second = try await authority.issuePreview(for: secondPlan)

        #expect(first.requiredConfirmation.text != second.requiredConfirmation.text)
        await #expect(throws: DatabaseConfirmationError.confirmationTextMismatch) {
            try await authority.authorizeAndExecute(
                token: first.token,
                plan: firstPlan,
                confirmationText: second.requiredConfirmation.text
            ) { _, _ in
                "unexpected"
            }
        }
        let result = try await authority.authorizeAndExecute(
            token: first.token,
            plan: firstPlan,
            confirmationText: first.requiredConfirmation.text
        ) { _, _ in
            "executed"
        }
        #expect(result == "executed")
    }

    @Test func rejectsTamperedMalformedNoncanonicalAndExpiredTokens() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let issuedAt = Date(timeIntervalSince1970: 6_000)
        let clock = DatabaseConfirmationTestClock(issuedAt)
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        try await metadata.seedConnection(try DatabaseConfirmationFixtures.connection())
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let plan = DatabaseConfirmationFixtures.plan()
        let preview = try await authority.issuePreview(for: plan, lifetimeSeconds: 60)
        let parts = preview.token.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        let signature = String(parts[1])
        let replacement = signature.first == "A" ? "B" : "A"
        let alteredSignature = replacement + signature.dropFirst()
        let tampered = DatabaseConfirmationToken(
            rawValue: "\(parts[0]).\(alteredSignature)")
        await #expect(throws: DatabaseConfirmationError.invalidSignature) {
            try await authority.authorizeAndExecute(
                token: tampered,
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        let padded = DatabaseConfirmationToken(
            rawValue: "\(parts[0])=.\(parts[1])")
        await #expect(throws: DatabaseConfirmationError.malformedToken) {
            try await authority.authorizeAndExecute(
                token: padded,
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        await #expect(throws: DatabaseConfirmationError.malformedToken) {
            try await authority.authorizeAndExecute(
                token: DatabaseConfirmationToken(rawValue: "invalid.extra.segment"),
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        var aliasPreview = preview
        for _ in 0..<64
        where !aliasPreview.token.rawValue.contains("-")
            && !aliasPreview.token.rawValue.contains("_")
        {
            aliasPreview = try await authority.issuePreview(for: plan, lifetimeSeconds: 60)
        }
        let aliasedRaw = aliasPreview.token.rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        #expect(aliasedRaw != aliasPreview.token.rawValue)
        await #expect(throws: DatabaseConfirmationError.malformedToken) {
            try await authority.authorizeAndExecute(
                token: DatabaseConfirmationToken(rawValue: aliasedRaw),
                plan: plan,
                confirmationText: aliasPreview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        let wrongKey = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore,
            signingKey: Data(repeating: 9, count: 32))
        await #expect(throws: DatabaseConfirmationError.invalidSignature) {
            try await wrongKey.authorizeAndExecute(
                token: preview.token,
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        clock.set(Date(timeIntervalSince1970: 5_969))
        await #expect(throws: DatabaseConfirmationError.issuedInFuture) {
            try await authority.authorizeAndExecute(
                token: preview.token,
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        clock.set(preview.expiresAt)
        await #expect(throws: DatabaseConfirmationError.expired) {
            try await authority.authorizeAndExecute(
                token: preview.token,
                plan: plan,
                confirmationText: preview.requiredConfirmation.text
            ) { _, _ in "unexpected" }
        }
        await #expect(throws: DatabaseConfirmationError.invalidLifetimeSeconds(301)) {
            try await authority.issuePreview(for: plan, lifetimeSeconds: 301)
        }
    }

    @Test func concurrentExecutionRunsOnceAndFailuresBurnReceipts() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = DatabaseConfirmationTestClock(Date(timeIntervalSince1970: 7_000))
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        try await metadata.seedConnection(try DatabaseConfirmationFixtures.connection())
        let first = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let second = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)
        let plan = DatabaseConfirmationFixtures.plan()
        let preview = try await first.issuePreview(for: plan)
        let probe = DatabaseConfirmationExecutionProbe()
        async let firstAttempt = DatabaseConfirmationFixtures.execute(
            authority: first,
            token: preview.token,
            plan: plan,
            confirmationText: preview.requiredConfirmation.text,
            probe: probe)
        async let secondAttempt = DatabaseConfirmationFixtures.execute(
            authority: second,
            token: preview.token,
            plan: plan,
            confirmationText: preview.requiredConfirmation.text,
            probe: probe)
        let attempts = await [firstAttempt, secondAttempt]

        #expect(attempts.filter { $0 == .success("executed") }.count == 1)
        #expect(
            attempts.filter {
                $0 == .confirmationFailure(.alreadyConsumedOrUnknown)
            }.count == 1)
        #expect(await probe.count() == 1)

        let failingPreview = try await first.issuePreview(for: plan)
        await #expect(throws: DatabaseConfirmationOperationError.failed) {
            try await first.authorizeAndExecute(
                token: failingPreview.token,
                plan: plan,
                confirmationText: failingPreview.requiredConfirmation.text
            ) { _, _ in
                throw DatabaseConfirmationOperationError.failed
            }
        }
        await #expect(throws: DatabaseConfirmationError.alreadyConsumedOrUnknown) {
            try await second.authorizeAndExecute(
                token: failingPreview.token,
                plan: plan,
                confirmationText: failingPreview.requiredConfirmation.text
            ) { _, _ in
                await probe.invoke("unexpected")
            }
        }
        #expect(await probe.count() == 1)
    }

    @Test func boundsRecursiveInputsAndPrunesExpiredReceipts() async throws {
        let (directory, path) = try DatabasePersistenceFixtures.temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 8_000)
        let clock = DatabaseConfirmationTestClock(now)
        let secretStore = try InMemoryDatabaseSecretStore()
        let metadata = try SQLiteDatabaseMetadataStore(path: path)
        try await metadata.seedConnection(try DatabaseConfirmationFixtures.connection())
        let authority = try await DatabaseConfirmationFixtures.authority(
            path: path,
            clock: clock,
            secretStore: secretStore)

        let longCommand = String(
            repeating: "x",
            count: DatabaseConfirmationAuthority.maximumCommandBytes + 1)
        await #expect(
            throws: DatabaseConfirmationError.limitExceeded(
                name: "command",
                actual: DatabaseConfirmationAuthority.maximumCommandBytes + 1,
                maximum: DatabaseConfirmationAuthority.maximumCommandBytes)
        ) {
            try await authority.issuePreview(
                for: DatabaseConfirmationFixtures.plan(
                    payload: DatabaseConfirmationFixtures.payload(command: longCommand)))
        }

        var nestedValue = DatabaseValue.null
        for _ in 0...DatabaseConfirmationAuthority.maximumInputDepth {
            nestedValue = .array([nestedValue])
        }
        await #expect(
            throws: DatabaseConfirmationError.limitExceeded(
                name: "input depth",
                actual: DatabaseConfirmationAuthority.maximumInputDepth + 1,
                maximum: DatabaseConfirmationAuthority.maximumInputDepth)
        ) {
            try await authority.issuePreview(
                for: DatabaseConfirmationFixtures.plan(
                    payload: DatabaseConfirmationFixtures.payload(body: nestedValue)))
        }

        let warnings = (0...DatabaseConfirmationAuthority.maximumWarningCount).map {
            DatabaseWarning(code: "warning-\($0)", message: "review", severity: .caution)
        }
        await #expect(
            throws: DatabaseConfirmationError.limitExceeded(
                name: "warnings",
                actual: DatabaseConfirmationAuthority.maximumWarningCount + 1,
                maximum: DatabaseConfirmationAuthority.maximumWarningCount)
        ) {
            try await authority.issuePreview(
                for: DatabaseConfirmationFixtures.plan(warnings: warnings))
        }

        let runtimeOwner = try #require(try await metadata.runtimeOwner()?.token)
        for _ in 0...100 {
            try await metadata.registerConfirmation(
                DatabaseConfirmationReceipt(
                    identifier: UUID(),
                    effectDigest: "expired",
                    expiresAt: now.addingTimeInterval(-1)),
                owner: runtimeOwner)
        }
        _ = try await authority.issuePreview(for: DatabaseConfirmationFixtures.plan())
        let remainder = try await metadata.removeExpiredConfirmations(
            before: now,
            owner: runtimeOwner)
        #expect(remainder.removedCount == 1)
        #expect(!remainder.hasMore)
    }
}
