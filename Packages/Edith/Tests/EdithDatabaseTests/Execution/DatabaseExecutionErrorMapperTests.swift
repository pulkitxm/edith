import Foundation
import Testing

@testable import EdithDatabase

private struct DatabaseExecutionOpaqueFailure: Error, CustomStringConvertible, LocalizedError,
    Sendable
{
    let description = "private driver description"
    var errorDescription: String? { "private localized description" }
}

private enum DatabaseExecutionErrorMapperFixtures {
    static let secret = "known-secret-value"
    static let secretReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "5E887319-0A7C-4529-AAB9-E5E90EAAB9E6")!,
        purpose: .password)

    static func mapper(secret: String = secret) async throws -> DatabaseExecutionErrorMapper {
        let store = try InMemoryDatabaseSecretStore(
            initialValues: [secretReference: Data(secret.utf8)])
        let redactor = try await DatabaseSecretRedactor(
            store: store,
            references: [secretReference])
        return DatabaseExecutionErrorMapper(redactor: redactor)
    }

    static func emptyRedactorMapper() async throws -> DatabaseExecutionErrorMapper {
        let store = try InMemoryDatabaseSecretStore()
        let redactor = try await DatabaseSecretRedactor(store: store, references: [])
        return DatabaseExecutionErrorMapper(redactor: redactor)
    }

    static func target(
        secret: String = secret,
        components: [DatabaseIdentityComponent]? = nil
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: DatabaseConnectionFixtures.connectionID,
            object: DatabaseObjectIdentifier(
                kind: .table,
                path: ["schema-\(secret)", "table-\(secret)"],
                nativeIdentifier: "native-\(secret)"),
            record: DatabaseRecordIdentity(
                kind: .primaryKey,
                components: components ?? typedComponents(secret: secret),
                concurrencyTokens: [
                    DatabaseIdentityComponent(
                        name: "version-\(secret)",
                        value: .string("token-\(secret)"))
                ]))
    }

    static func typedComponents(secret: String) -> [DatabaseIdentityComponent] {
        let secretData = Data(secret.utf8)
        return [
            DatabaseIdentityComponent(
                name: "decimal-\(secret)",
                value: .decimal(DatabaseDecimalValue(rawValue: "12.50-\(secret)"))),
            DatabaseIdentityComponent(
                name: "string-\(secret)",
                value: .string("text-\(secret)")),
            DatabaseIdentityComponent(
                name: "binary-\(secret)",
                value: .binary(
                    .complete(
                        data: secretData,
                        mediaType: "media-\(secret)",
                        digest: "digest-\(secret)"))),
            DatabaseIdentityComponent(
                name: "date-\(secret)",
                value: .date(
                    DatabaseDateValue(
                        text: "2026-08-30-\(secret)",
                        calendarIdentifier: "calendar-\(secret)"))),
            DatabaseIdentityComponent(
                name: "time-\(secret)",
                value: .time(DatabaseTimeValue(text: "12:00:00-\(secret)"))),
            DatabaseIdentityComponent(
                name: "timestamp-\(secret)",
                value: .timestamp(
                    DatabaseTimestampValue(
                        text: "2026-08-30T12:00:00-\(secret)",
                        timeZoneIdentifier: "zone-\(secret)"))),
            DatabaseIdentityComponent(
                name: "array-\(secret)",
                value: .array([.string("array-\(secret)")])),
            DatabaseIdentityComponent(
                name: "object-\(secret)",
                value: .object([
                    DatabaseObjectField(
                        name: "field-\(secret)",
                        value: .string("object-\(secret)"))
                ])),
            DatabaseIdentityComponent(
                name: "product-\(secret)",
                value: .productSpecific(
                    DatabaseProductValue(
                        product: .postgresql,
                        typeName: "type-\(secret)",
                        textRepresentation: "representation-\(secret)",
                        binaryRepresentation: secretData,
                        attributes: [
                            DatabaseStringAttribute(
                                name: "attribute-\(secret)",
                                value: "value-\(secret)")
                        ]))),
        ]
    }

    static func reportedEnvelope(secret: String = secret) -> DatabaseErrorEnvelope {
        DatabaseErrorEnvelope(
            category: .server,
            message: "message-\(secret)",
            productCode: "code-\(secret)",
            target: target(secret: secret),
            retry: DatabaseRetryGuidance(
                action: .retry,
                afterMilliseconds: 250,
                message: "retry-\(secret)"),
            partialResult: DatabaseResultCompleteness(
                state: .partial,
                reason: "partial-\(secret)"),
            details: [
                DatabaseErrorDetail(
                    name: "detail-\(secret)",
                    value: "detail-value-\(secret)")
            ])
    }

    static func assertMapping(
        _ mapper: DatabaseExecutionErrorMapper,
        error: any Error,
        category: DatabaseErrorCategory,
        retry: DatabaseRetryAction
    ) {
        let envelope = mapper.map(error)
        #expect(envelope.category == category)
        #expect(envelope.retry.action == retry)
    }
}

@Suite struct DatabaseExecutionErrorFamilyMappingTests {
    @Test func validationMappingsHaveStableCategoriesAndRetryActions() {
        let mapper = DatabaseExecutionErrorMapper()
        let cases: [(any Error, DatabaseErrorCategory, DatabaseRetryAction)] = [
            (DatabaseExecutionValidationError.deadlineExceeded, .timeout, .retry),
            (
                DatabaseExecutionValidationError.operationIdentifierAlreadyExists(
                    DatabaseOperationFixtures.operationID),
                .conflict,
                .none
            ),
            (
                DatabaseExecutionValidationError.runtimeOwnerNotActive,
                .conflict,
                .reconnect
            ),
            (
                DatabaseExecutionValidationError.limitExceeded(
                    name: "rows",
                    actual: 2_001,
                    maximum: 2_000),
                .resourceLimit,
                .none
            ),
            (
                DatabaseExecutionValidationError.capabilityUnavailable(
                    .browse,
                    DatabaseCapabilityUnavailableReason(
                        category: .permission,
                        message: "private permission message")),
                .permissionDenied,
                .refreshCapabilities
            ),
            (
                DatabaseExecutionValidationError.queryLanguageMismatch(
                    language: .mongoQuery,
                    product: .postgresql),
                .invalidRequest,
                .none
            ),
        ]

        for (error, category, retry) in cases {
            DatabaseExecutionErrorMapperFixtures.assertMapping(
                mapper,
                error: error,
                category: category,
                retry: retry)
        }
    }

    @Test func adapterMappingsDistinguishCancellationLimitsAndSupport() {
        let mapper = DatabaseExecutionErrorMapper()
        let cases: [(DatabaseAdapterFailure, DatabaseErrorCategory, DatabaseRetryAction)] = [
            (.cancelled, .cancelled, .none),
            (
                .limitExceeded(limit: .pageRecords, actual: 2_001, maximum: 2_000),
                .resourceLimit,
                .none
            ),
            (
                .contractViolation(.unsupportedProduct(.mongoDB)),
                .unsupported,
                .none
            ),
            (
                .contractViolation(.staleSession),
                .internalFailure,
                .none
            ),
        ]

        for (error, category, retry) in cases {
            DatabaseExecutionErrorMapperFixtures.assertMapping(
                mapper,
                error: error,
                category: category,
                retry: retry)
        }
    }

    @Test func confirmationMappingsPreserveSafetyRecovery() {
        let mapper = DatabaseExecutionErrorMapper()
        let cases: [(DatabaseConfirmationError, DatabaseErrorCategory, DatabaseRetryAction)] = [
            (.expired, .confirmationInvalid, .createNewPreview),
            (.effectMismatch, .confirmationInvalid, .createNewPreview),
            (.confirmationTextMismatch, .confirmationInvalid, .userDecision),
            (
                .mutationProhibited(.environmentReadOnly),
                .readOnlyViolation,
                .none
            ),
            (.invalidRequest("private mutation detail"), .invalidRequest, .none),
            (.invalidSigningKeyBytes(3), .internalFailure, .none),
        ]

        for (error, category, retry) in cases {
            DatabaseExecutionErrorMapperFixtures.assertMapping(
                mapper,
                error: error,
                category: category,
                retry: retry)
        }
    }

    @Test func persistenceAndSecretMappingsStayActionableWithoutRawDetails() {
        let mapper = DatabaseExecutionErrorMapper()
        let reference = DatabaseExecutionErrorMapperFixtures.secretReference
        let cases: [(any Error, DatabaseErrorCategory, DatabaseRetryAction)] = [
            (
                DatabaseMetadataStoreError.invalidLimit(-1),
                .invalidRequest,
                .none
            ),
            (
                DatabaseMetadataStoreError.valueTooLarge(
                    name: "private field",
                    bytes: 20,
                    maximum: 10),
                .resourceLimit,
                .none
            ),
            (
                DatabaseMetadataStoreError.corruptedRecord(
                    kind: "private kind",
                    identifier: "private identifier"),
                .decoding,
                .none
            ),
            (
                DatabaseSecretStoreError.notFound(reference),
                .authenticationFailed,
                .reauthenticate
            ),
            (
                DatabaseSecretStoreError.keychainFailure(operation: .read, status: -50),
                .internalFailure,
                .userDecision
            ),
            (
                DatabaseSecretStoreError.secretTooLarge(
                    actualBytes: 2,
                    maximumBytes: 1),
                .resourceLimit,
                .none
            ),
            (
                DatabaseSecretRedactorError.tooManyReferences(actual: 257, maximum: 256),
                .resourceLimit,
                .none
            ),
        ]

        for (error, category, retry) in cases {
            DatabaseExecutionErrorMapperFixtures.assertMapping(
                mapper,
                error: error,
                category: category,
                retry: retry)
        }
    }

    @Test func cancellationAndUnexpectedErrorsAreOpaque() throws {
        let mapper = DatabaseExecutionErrorMapper()
        let cancelled = mapper.map(CancellationError())

        #expect(cancelled.category == .cancelled)
        #expect(cancelled.retry.action == .none)

        let unexpected = mapper.map(DatabaseExecutionOpaqueFailure())
        let encoded = try JSONEncoder().encode(unexpected)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(unexpected.category == .internalFailure)
        #expect(unexpected.message == "The database operation failed unexpectedly.")
        #expect(!text.contains("private driver description"))
        #expect(!text.contains("private localized description"))
        #expect(unexpected.details.isEmpty)
    }
}

@Suite struct DatabaseExecutionErrorRedactionTests {
    @Test func adapterReportedEnvelopeRemainsOpaqueWithARedactor() async throws {
        let secret = DatabaseExecutionErrorMapperFixtures.secret
        let mapper = try await DatabaseExecutionErrorMapperFixtures.mapper(secret: secret)
        let mapped = mapper.map(
            DatabaseAdapterFailure.reported(
                DatabaseExecutionErrorMapperFixtures.reportedEnvelope(secret: secret)))
        let text = String(decoding: try JSONEncoder().encode(mapped), as: UTF8.self)

        #expect(mapped.category == .server)
        #expect(mapped.message == "The database server rejected the operation.")
        #expect(mapped.productCode == nil)
        #expect(mapped.target == nil)
        #expect(mapped.details.isEmpty)
        #expect(!text.contains(secret))
    }

    @Test func reportedEnvelopeRedactsEveryStringAndTypedTargetValue() async throws {
        let secret = DatabaseExecutionErrorMapperFixtures.secret
        let mapper = try await DatabaseExecutionErrorMapperFixtures.mapper(secret: secret)
        let mapped = mapper.map(
            DatabaseExecutionErrorMapperFixtures.reportedEnvelope(secret: secret))
        let encoded = try JSONEncoder().encode(mapped)
        let text = String(decoding: encoded, as: UTF8.self)
        let encodedSecret = Data(secret.utf8).base64EncodedString()

        #expect(mapped.category == .server)
        #expect(mapped.retry.action == .retry)
        #expect(mapped.target != nil)
        #expect(mapped.details.count == 1)
        #expect(text.contains(DatabaseSecretRedactor.defaultReplacement))
        #expect(!text.contains(secret))
        #expect(!text.contains(encodedSecret))

        let binaryComponent = mapped.target?.record?.components.first {
            $0.name.hasPrefix("binary-")
        }
        guard case let .binary(.complete(data, mediaType, digest)) = binaryComponent?.value else {
            Issue.record("The redacted binary identity component is missing.")
            return
        }
        #expect(data == Data(DatabaseSecretRedactor.defaultReplacement.utf8))
        #expect(mediaType == "media-\(DatabaseSecretRedactor.defaultReplacement)")
        #expect(digest == "digest-\(DatabaseSecretRedactor.defaultReplacement)")

        let productComponent = mapped.target?.record?.components.first {
            $0.name.hasPrefix("product-")
        }
        guard case let .productSpecific(productValue) = productComponent?.value else {
            Issue.record("The redacted product identity component is missing.")
            return
        }
        #expect(
            productValue.binaryRepresentation
                == Data(DatabaseSecretRedactor.defaultReplacement.utf8))
        #expect(
            productValue.attributes.first?.value
                == "value-\(DatabaseSecretRedactor.defaultReplacement)")
    }

    @Test func reportedEnvelopeEnforcesEveryOutputBound() async throws {
        let mapper = try await DatabaseExecutionErrorMapperFixtures.emptyRedactorMapper()
        let longMessage = String(
            repeating: "m",
            count: DatabaseExecutionErrorMapper.maximumMessageBytes + 1)
        let longProductCode = String(
            repeating: "p",
            count: DatabaseExecutionErrorMapper.maximumProductCodeBytes + 1)
        let longRetry = String(
            repeating: "r",
            count: DatabaseExecutionErrorMapper.maximumRetryMessageBytes + 1)
        let longReason = String(
            repeating: "c",
            count: DatabaseExecutionErrorMapper.maximumCompletenessReasonBytes + 1)
        let longDetailName = String(
            repeating: "n",
            count: DatabaseExecutionErrorMapper.maximumDetailNameBytes + 1)
        let longDetailValue = String(
            repeating: "v",
            count: DatabaseExecutionErrorMapper.maximumDetailValueBytes + 1)
        let longTargetValue = String(
            repeating: "t",
            count: DatabaseExecutionErrorMapper.maximumValueTextBytes + 1)
        let components = (0...DatabaseExecutionErrorMapper.maximumIdentityComponents).map {
            DatabaseIdentityComponent(
                name: "component-\($0)",
                value: .string(longTargetValue))
        }
        let target = DatabaseTargetIdentifier(
            connectionID: DatabaseConnectionFixtures.connectionID,
            object: DatabaseObjectIdentifier(
                kind: .table,
                path: (0...DatabaseExecutionErrorMapper.maximumTargetPathSegments).map {
                    "path-\($0)"
                }),
            record: DatabaseRecordIdentity(
                kind: .primaryKey,
                components: components))
        let reported = DatabaseErrorEnvelope(
            category: .partialFailure,
            message: longMessage,
            productCode: longProductCode,
            target: target,
            retry: DatabaseRetryGuidance(
                action: .userDecision,
                afterMilliseconds: DatabaseExecutionErrorMapper.maximumRetryDelayMilliseconds + 1,
                message: longRetry),
            partialResult: DatabaseResultCompleteness(
                state: .partial,
                reason: longReason),
            details: (0...DatabaseExecutionErrorMapper.maximumDetailCount).map { _ in
                DatabaseErrorDetail(name: longDetailName, value: longDetailValue)
            })
        let mapped = mapper.map(reported)

        #expect(mapped.message == DatabaseExecutionErrorMapper.truncationMarker)
        #expect(mapped.productCode == DatabaseExecutionErrorMapper.truncationMarker)
        #expect(mapped.retry.message == DatabaseExecutionErrorMapper.truncationMarker)
        #expect(
            mapped.retry.afterMilliseconds
                == DatabaseExecutionErrorMapper.maximumRetryDelayMilliseconds)
        #expect(mapped.partialResult?.reason == DatabaseExecutionErrorMapper.truncationMarker)
        #expect(mapped.details.count == DatabaseExecutionErrorMapper.maximumDetailCount)
        #expect(
            mapped.details.allSatisfy {
                $0.name == DatabaseExecutionErrorMapper.truncationMarker
                    && $0.value == DatabaseExecutionErrorMapper.truncationMarker
            })
        #expect(
            mapped.target?.object?.path.count
                == DatabaseExecutionErrorMapper.maximumTargetPathSegments)
        #expect(
            mapped.target?.record?.components.count
                == DatabaseExecutionErrorMapper.maximumIdentityComponents)
        #expect(
            mapped.target?.record?.components.allSatisfy {
                $0.value == .string(DatabaseExecutionErrorMapper.truncationMarker)
            } == true)
    }

    @Test func reportedEnvelopeWithoutRedactorDropsAllSuppliedTextAndTargetData() throws {
        let secret = DatabaseExecutionErrorMapperFixtures.secret
        let mapper = DatabaseExecutionErrorMapper()
        let reported = DatabaseErrorEnvelope(
            category: .network,
            message: "message-\(secret)",
            productCode: "code-\(secret)",
            target: DatabaseExecutionErrorMapperFixtures.target(secret: secret),
            retry: DatabaseRetryGuidance(
                action: .retry,
                afterMilliseconds: 10,
                message: "retry-\(secret)"),
            partialResult: DatabaseResultCompleteness(
                state: .partial,
                reason: "reason-\(secret)"),
            details: [
                DatabaseErrorDetail(name: "name-\(secret)", value: "value-\(secret)")
            ])
        let mapped = mapper.map(DatabaseAdapterFailure.reported(reported))
        let encoded = try JSONEncoder().encode(mapped)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(mapped.category == .network)
        #expect(mapped.message == "The database network request failed.")
        #expect(mapped.productCode == nil)
        #expect(mapped.target == nil)
        #expect(mapped.retry.action == .reconnect)
        #expect(mapped.partialResult?.state == .partial)
        #expect(mapped.partialResult?.reason == nil)
        #expect(mapped.details.isEmpty)
        #expect(!text.contains(secret))
    }
}

@Suite struct DatabaseExecutionCapabilityMappingTests {
    @Test func destructiveActionsMapToTheirEnforcedCapabilities() {
        let cases: [(DatabaseDestructiveAction, DatabaseCapabilityID)] = [
            (.insert, .insert),
            (.update, .update),
            (.updateMany, .bulkMutation),
            (.delete, .delete),
            (.deleteMany, .bulkMutation),
            (.truncate, .delete),
            (.dropObject, .schemaMutation),
            (.schemaChange, .schemaMutation),
            (.permissionChange, .administration),
            (.terminateSession, .administration),
            (.maintenance, .administration),
            (.reindex, .administration),
            (.asynchronousMutation, .bulkMutation),
        ]

        for (action, capability) in cases {
            #expect(
                DatabaseExecutionErrorMapper.requiredCapability(for: action) == capability)
        }
    }
}
