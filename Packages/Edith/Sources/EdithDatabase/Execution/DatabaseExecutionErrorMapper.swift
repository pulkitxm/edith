import Foundation

struct DatabaseExecutionErrorMapper: Sendable {
    static let maximumMessageBytes = 8_192
    static let maximumProductCodeBytes = 1_024
    static let maximumRetryMessageBytes = 4_096
    static let maximumCompletenessReasonBytes = 4_096
    static let maximumDetailCount = 32
    static let maximumDetailNameBytes = 256
    static let maximumDetailValueBytes = 4_096
    static let maximumTargetPathSegments = 64
    static let maximumTargetSegmentBytes = 4_096
    static let maximumIdentityComponents = 64
    static let maximumValueDepth = 32
    static let maximumValueNodes = 10_000
    static let maximumValueCollectionElements = 256
    static let maximumValueTextBytes = 4_096
    static let maximumValueBinaryBytes = 4_096
    static let maximumProductAttributes = 64
    static let maximumRetryDelayMilliseconds: UInt64 = 86_400_000
    static let truncationMarker = "[TRUNCATED]"

    private let redactor: DatabaseSecretRedactor?

    init(redactor: DatabaseSecretRedactor? = nil) {
        self.redactor = redactor
    }

    func map(
        _ error: any Error,
        target: DatabaseTargetIdentifier? = nil
    ) -> DatabaseErrorEnvelope {
        if let validation = error as? DatabaseExecutionValidationError {
            return map(validation, target: target)
        }
        if let adapter = error as? DatabaseAdapterFailure {
            return map(adapter, target: target)
        }
        if let confirmation = error as? DatabaseConfirmationError {
            return map(confirmation, target: target)
        }
        if let continuation = error as? DatabaseContinuationAuthorityError {
            return map(continuation, target: target)
        }
        if let metadata = error as? DatabaseMetadataStoreError {
            return map(metadata, target: target)
        }
        if let secret = error as? DatabaseSecretStoreError {
            return map(secret, target: target)
        }
        if let redactorError = error as? DatabaseSecretRedactorError {
            return map(redactorError, target: target)
        }
        if let envelope = error as? DatabaseErrorEnvelope {
            return sanitize(envelope)
        }
        if error is CancellationError {
            return envelope(
                category: .cancelled,
                message: "The database operation was cancelled.",
                target: target)
        }
        return envelope(
            category: .internalFailure,
            message: "The database operation failed unexpectedly.",
            target: target)
    }

    static func requiredCapability(
        for action: DatabaseDestructiveAction
    ) -> DatabaseCapabilityID {
        switch action {
        case .insert:
            .insert
        case .update:
            .update
        case .updateMany:
            .bulkMutation
        case .delete, .truncate:
            .delete
        case .deleteMany, .asynchronousMutation:
            .bulkMutation
        case .dropObject, .schemaChange:
            .schemaMutation
        case .permissionChange, .terminateSession, .maintenance, .reindex:
            .administration
        }
    }

    func sanitize(
        _ identity: DatabaseConnectionIdentity
    ) -> DatabaseConnectionIdentity {
        DatabaseConnectionIdentity(
            id: identity.id,
            displayName: redactor == nil
                ? "Database connection"
                : redactText(identity.displayName, maximumBytes: Self.maximumTargetSegmentBytes),
            productHint: identity.productHint,
            environment: DatabaseEnvironmentMetadata(
                kind: identity.environment.kind,
                label: redactor == nil
                    ? identity.environment.kind.rawValue
                    : redactText(
                        identity.environment.label,
                        maximumBytes: Self.maximumTargetSegmentBytes),
                protection: identity.environment.protection))
    }

    func sanitize(
        _ target: DatabaseTargetIdentifier?
    ) -> DatabaseTargetIdentifier? {
        target.flatMap(sanitizeTarget)
    }

    func sanitize(_ warning: DatabaseWarning) -> DatabaseWarning {
        guard redactor != nil else {
            return DatabaseWarning(
                code: "database.warning.redacted",
                message: "A database warning was reported.",
                severity: warning.severity)
        }
        return DatabaseWarning(
            code: redactText(warning.code, maximumBytes: Self.maximumDetailNameBytes),
            message: redactText(warning.message, maximumBytes: Self.maximumMessageBytes),
            severity: warning.severity,
            target: warning.target.flatMap(sanitizeTarget))
    }

    func sanitizeServerOperationIdentifier(_ identifier: String?) -> String? {
        guard redactor != nil else { return nil }
        return identifier.map {
            redactText(
                $0,
                maximumBytes: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
        }
    }

    private func map(
        _ error: DatabaseExecutionValidationError,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case let .unsupportedVersion(_, expected, actual):
            envelope(
                category: .invalidRequest,
                message: "The request contract version is unsupported.",
                target: target,
                details: countDetails(actual: actual, maximum: expected))
        case .deadlineExceeded:
            envelope(
                category: .timeout,
                message: "The database operation deadline has already passed.",
                retry: retry(
                    .retry,
                    "Submit a new request with a later deadline."),
                target: target)
        case .operationIdentifierAlreadyExists:
            envelope(
                category: .conflict,
                message: "The database operation identifier is already in use.",
                target: target)
        case .identifierAlreadyExists:
            envelope(
                category: .conflict,
                message: "The database resource identifier is already in use.",
                target: target)
        case .connectionDefinitionChanged:
            envelope(
                category: .conflict,
                message: "The saved database connection changed before the operation started.",
                retry: retry(
                    .reconnect,
                    "Reconnect using the current saved connection before retrying."),
                target: target)
        case .savedQueryDefinitionChanged:
            envelope(
                category: .conflict,
                message: "The saved database query changed before the operation started.",
                retry: retry(
                    .retry,
                    "Reload the saved query before retrying."),
                target: target)
        case .runtimeOwnerNotActive:
            envelope(
                category: .conflict,
                message: "The database runtime owner is no longer active.",
                retry: retry(
                    .reconnect,
                    "Restart the database runtime before retrying."),
                target: target)
        case .invalidIdentifier, .invalidDefinition, .duplicateValue,
            .suspiciousOptionName, .invalidTimestamp:
            envelope(
                category: .invalidRequest,
                message: "The database management request is invalid.",
                target: target)
        case .invalidTarget:
            envelope(
                category: .invalidRequest,
                message: "The database target is invalid.",
                target: target)
        case .emptyCommand:
            envelope(
                category: .invalidRequest,
                message: "The database command is empty.",
                target: target)
        case let .queryLanguageMismatch(language, product):
            envelope(
                category: .invalidRequest,
                message: "The query language does not match the database product.",
                target: target,
                details: [
                    DatabaseErrorDetail(name: "language", value: language.rawValue),
                    DatabaseErrorDetail(name: "product", value: product.rawValue),
                ])
        case let .queryBodyNotAllowed(language):
            envelope(
                category: .invalidRequest,
                message: "The query language does not accept a request body.",
                target: target,
                details: [
                    DatabaseErrorDetail(name: "language", value: language.rawValue)
                ])
        case let .limitExceeded(_, actual, maximum),
            let .encodedSizeExceeded(_, actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "The database request exceeds a safety limit.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        case let .productMismatch(expected, actual):
            envelope(
                category: .invalidRequest,
                message: "The request product does not match the connection.",
                retry: retry(
                    .refreshCapabilities,
                    "Refresh the connection capabilities before retrying."),
                target: target,
                details: [
                    DatabaseErrorDetail(name: "expectedProduct", value: expected.rawValue),
                    DatabaseErrorDetail(name: "actualProduct", value: actual.rawValue),
                ])
        case let .capabilityUnavailable(_, reason):
            capabilityUnavailable(reason: reason, target: target)
        case .invalidAdapterResult:
            envelope(
                category: .internalFailure,
                message: "The database adapter returned an invalid result.",
                target: target)
        }
    }

    private func map(
        _ error: DatabaseAdapterFailure,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case let .reported(reported):
            DatabaseExecutionErrorMapper().sanitize(reported)
        case .cancelled:
            envelope(
                category: .cancelled,
                message: "The database operation was cancelled.",
                target: target)
        case let .limitExceeded(_, actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "The database adapter exceeded a safety limit.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        case let .contractViolation(violation):
            switch violation {
            case .unsupportedProduct:
                envelope(
                    category: .unsupported,
                    message: "No database adapter supports this product.",
                    target: target)
            case .emptyAdapterIdentifier, .duplicateAdapterIdentifier,
                .duplicateProductRegistration, .capabilityIdentityMismatch,
                .duplicateCapability, .pageExceedsRequest,
                .streamBatchExceedsRequest, .encodingFailed, .staleSession,
                .unexpectedMutationPlan, .partialMutationResult:
                envelope(
                    category: .internalFailure,
                    message: "The database adapter violated its execution contract.",
                    target: target)
            }
        }
    }

    private func map(
        _ error: DatabaseConfirmationError,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case .invalidSigningKeyBytes:
            envelope(
                category: .internalFailure,
                message: "Database confirmation security is unavailable.",
                target: target)
        case let .invalidLifetimeSeconds(actual):
            envelope(
                category: .invalidRequest,
                message: "The confirmation lifetime is invalid.",
                target: target,
                details: [
                    DatabaseErrorDetail(name: "actual", value: String(actual))
                ])
        case .connectionNotFound:
            envelope(
                category: .invalidRequest,
                message: "The database connection no longer exists.",
                target: target)
        case .productMismatch:
            envelope(
                category: .confirmationInvalid,
                message: "The confirmation no longer matches the database product.",
                retry: newPreviewRetry(),
                target: target)
        case .mutationProhibited:
            envelope(
                category: .readOnlyViolation,
                message: "The connection policy prohibits this mutation.",
                target: target)
        case .invalidRequest:
            envelope(
                category: .invalidRequest,
                message: "The mutation request is invalid.",
                target: target)
        case let .limitExceeded(_, actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "The mutation preview exceeds a safety limit.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        case .confirmationTextMismatch:
            envelope(
                category: .confirmationInvalid,
                message: "The confirmation text does not match the required value.",
                retry: retry(
                    .userDecision,
                    "Review the preview and enter the required confirmation text."),
                target: target)
        case .malformedToken, .unsupportedVersion, .invalidSignature, .issuedInFuture,
            .expired, .lifetimeExceeded, .effectMismatch, .alreadyConsumedOrUnknown:
            envelope(
                category: .confirmationInvalid,
                message: "The mutation confirmation is invalid or expired.",
                retry: newPreviewRetry(),
                target: target)
        }
    }

    private func map(
        _ error: DatabaseContinuationAuthorityError,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case .invalidSigningKeyBytes:
            envelope(
                category: .internalFailure,
                message: "Database continuation security is unavailable.",
                target: target)
        case .invalidLifetimeSeconds, .invalidRequest:
            envelope(
                category: .invalidRequest,
                message: "The database continuation request is invalid.",
                target: target)
        case .malformedToken, .unsupportedVersion, .invalidAudience,
            .invalidSignature, .issuedInFuture, .expired, .lifetimeExceeded,
            .contextMismatch, .malformedPayload:
            envelope(
                category: .invalidRequest,
                message: "The database continuation is invalid or expired.",
                retry: retry(
                    .retry,
                    "Restart the read without a continuation."),
                target: target)
        case let .payloadLimitExceeded(actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "The database continuation exceeds a safety limit.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        }
    }

    private func map(
        _ error: DatabaseMetadataStoreError,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case let .invalidLimit(actual):
            envelope(
                category: .invalidRequest,
                message: "The metadata query limit is invalid.",
                target: target,
                details: [
                    DatabaseErrorDetail(name: "actual", value: String(actual))
                ])
        case let .invalidOffset(actual):
            envelope(
                category: .invalidRequest,
                message: "The metadata query offset is invalid.",
                target: target,
                details: [
                    DatabaseErrorDetail(name: "actual", value: String(actual))
                ])
        case let .valueTooLarge(_, bytes, maximum):
            envelope(
                category: .resourceLimit,
                message: "The metadata value exceeds a safety limit.",
                target: target,
                details: countDetails(actual: bytes, maximum: maximum))
        case .invalidValue:
            envelope(
                category: .invalidRequest,
                message: "The metadata value is invalid.",
                target: target)
        case .connectionNotFound:
            envelope(
                category: .invalidRequest,
                message: "The database connection was not found.",
                target: target)
        case .savedQueryNotFound:
            envelope(
                category: .invalidRequest,
                message: "The saved database query was not found.",
                target: target)
        case .runtimeOwnerNotActive:
            envelope(
                category: .conflict,
                message: "The database runtime owner is no longer active.",
                retry: retry(
                    .reconnect,
                    "Restart the database runtime before retrying."),
                target: target)
        case .corruptedRecord:
            envelope(
                category: .decoding,
                message: "Stored database metadata could not be decoded.",
                target: target)
        }
    }

    private func map(
        _ error: DatabaseSecretStoreError,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case .invalidService, .invalidLabel, .invalidMaximumSecretBytes,
            .keychainFailure:
            envelope(
                category: .internalFailure,
                message: "Secure database credential storage is unavailable.",
                retry: retry(
                    .userDecision,
                    "Review the local credential storage configuration."),
                target: target)
        case let .secretTooLarge(actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "The database credential exceeds the storage limit.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        case let .storedSecretTooLarge(_, maximum):
            envelope(
                category: .resourceLimit,
                message: "The stored database credential exceeds the storage limit.",
                target: target,
                details: [
                    DatabaseErrorDetail(name: "maximum", value: String(maximum))
                ])
        case .notFound, .invalidStoredData:
            envelope(
                category: .authenticationFailed,
                message: "The database credential is missing or invalid.",
                retry: retry(
                    .reauthenticate,
                    "Replace the saved credential before reconnecting."),
                target: target)
        }
    }

    private func map(
        _ error: DatabaseSecretRedactorError,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        switch error {
        case .invalidReplacement:
            envelope(
                category: .internalFailure,
                message: "Database error redaction is unavailable.",
                target: target)
        case let .tooManyReferences(actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "Too many database credentials were selected for redaction.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        case let .secretMaterialTooLarge(actual, maximum):
            envelope(
                category: .resourceLimit,
                message: "Database credential material exceeds the redaction limit.",
                target: target,
                details: countDetails(actual: actual, maximum: maximum))
        }
    }

    private func capabilityUnavailable(
        reason: DatabaseCapabilityUnavailableReason?,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        let category: DatabaseErrorCategory
        let retryGuidance: DatabaseRetryGuidance
        switch reason?.category {
        case .permission:
            category = .permissionDenied
            retryGuidance = retry(
                .refreshCapabilities,
                "Refresh capabilities after the account permissions change.")
        case .connectionPolicy, .unsafe:
            category = .readOnlyViolation
            retryGuidance = retry(.userDecision, "Review the connection safety policy.")
        case .version, .topology, .module, .plugin, .configuration, .unknown:
            category = .unsupported
            retryGuidance = retry(
                .refreshCapabilities,
                "Refresh the connection capabilities before retrying.")
        case .product, .license, .notImplemented, .none:
            category = .unsupported
            retryGuidance = retry(.none)
        }
        return envelope(
            category: category,
            message: "The requested database capability is unavailable.",
            retry: retryGuidance,
            target: target)
    }

    private func sanitize(_ envelope: DatabaseErrorEnvelope) -> DatabaseErrorEnvelope {
        guard redactor != nil else {
            return DatabaseErrorEnvelope(
                category: envelope.category,
                message: opaqueMessage(for: envelope.category),
                retry: defaultRetry(for: envelope.category),
                partialResult: envelope.partialResult.map {
                    DatabaseResultCompleteness(state: $0.state)
                })
        }
        let safeTarget = envelope.target.flatMap(sanitizeTarget)
        let safeRetry = DatabaseRetryGuidance(
            action: envelope.retry.action,
            afterMilliseconds: envelope.retry.afterMilliseconds.map {
                min($0, Self.maximumRetryDelayMilliseconds)
            },
            message: envelope.retry.message.map {
                redactText($0, maximumBytes: Self.maximumRetryMessageBytes)
            })
        let safeCompleteness = envelope.partialResult.map {
            DatabaseResultCompleteness(
                state: $0.state,
                reason: $0.reason.map {
                    redactText($0, maximumBytes: Self.maximumCompletenessReasonBytes)
                })
        }
        let safeDetails = envelope.details.prefix(Self.maximumDetailCount).map {
            DatabaseErrorDetail(
                name: redactText($0.name, maximumBytes: Self.maximumDetailNameBytes),
                value: redactText($0.value, maximumBytes: Self.maximumDetailValueBytes))
        }
        return DatabaseErrorEnvelope(
            category: envelope.category,
            message: redactText(envelope.message, maximumBytes: Self.maximumMessageBytes),
            productCode: envelope.productCode.map {
                redactText($0, maximumBytes: Self.maximumProductCodeBytes)
            },
            target: safeTarget,
            retry: safeRetry,
            partialResult: safeCompleteness,
            details: safeDetails)
    }

    private func envelope(
        category: DatabaseErrorCategory,
        message: String,
        retry: DatabaseRetryGuidance = DatabaseRetryGuidance(action: .none),
        target: DatabaseTargetIdentifier?,
        details: [DatabaseErrorDetail] = []
    ) -> DatabaseErrorEnvelope {
        DatabaseErrorEnvelope(
            category: category,
            message: bounded(message, maximumBytes: Self.maximumMessageBytes),
            target: target.flatMap(sanitizeTarget),
            retry: retry,
            details: Array(details.prefix(Self.maximumDetailCount)))
    }

    private func sanitizeTarget(
        _ target: DatabaseTargetIdentifier
    ) -> DatabaseTargetIdentifier? {
        guard redactor != nil else { return nil }
        let object = target.object.map {
            DatabaseObjectIdentifier(
                kind: $0.kind,
                path: $0.path.prefix(Self.maximumTargetPathSegments).map {
                    redactText($0, maximumBytes: Self.maximumTargetSegmentBytes)
                },
                nativeIdentifier: $0.nativeIdentifier.map {
                    redactText($0, maximumBytes: Self.maximumTargetSegmentBytes)
                })
        }
        var budget = DatabaseErrorSanitizationBudget()
        let record = target.record.map {
            DatabaseRecordIdentity(
                kind: $0.kind,
                components: $0.components.prefix(Self.maximumIdentityComponents).map {
                    sanitizeIdentityComponent($0, budget: &budget)
                },
                concurrencyTokens: $0.concurrencyTokens.prefix(Self.maximumIdentityComponents)
                    .map {
                        sanitizeIdentityComponent($0, budget: &budget)
                    })
        }
        return DatabaseTargetIdentifier(
            connectionID: target.connectionID,
            object: object,
            record: record)
    }

    private func sanitizeIdentityComponent(
        _ component: DatabaseIdentityComponent,
        budget: inout DatabaseErrorSanitizationBudget
    ) -> DatabaseIdentityComponent {
        DatabaseIdentityComponent(
            name: redactText(
                component.name,
                maximumBytes: Self.maximumTargetSegmentBytes),
            value: sanitizeValue(component.value, depth: 1, budget: &budget))
    }

    private func sanitizeValue(
        _ value: DatabaseValue,
        depth: Int,
        budget: inout DatabaseErrorSanitizationBudget
    ) -> DatabaseValue {
        guard depth <= Self.maximumValueDepth, budget.nodes < Self.maximumValueNodes else {
            return .string(Self.truncationMarker)
        }
        budget.nodes += 1
        switch value {
        case .missing:
            return .missing
        case .null:
            return .null
        case let .boolean(value):
            return .boolean(value)
        case let .signedInteger(value):
            return .signedInteger(value)
        case let .unsignedInteger(value):
            return .unsignedInteger(value)
        case let .decimal(value):
            return .decimal(
                DatabaseDecimalValue(
                    rawValue: redactText(
                        value.rawValue,
                        maximumBytes: Self.maximumValueTextBytes)))
        case let .floatingPoint(value):
            return .floatingPoint(value)
        case let .string(value):
            return .string(redactText(value, maximumBytes: Self.maximumValueTextBytes))
        case let .binary(value):
            return .binary(sanitizeBinary(value))
        case let .date(value):
            return .date(
                DatabaseDateValue(
                    text: redactText(value.text, maximumBytes: Self.maximumValueTextBytes),
                    calendarIdentifier: value.calendarIdentifier.map {
                        redactText($0, maximumBytes: Self.maximumValueTextBytes)
                    }))
        case let .time(value):
            return .time(
                DatabaseTimeValue(
                    text: redactText(value.text, maximumBytes: Self.maximumValueTextBytes),
                    timeZoneOffsetMinutes: value.timeZoneOffsetMinutes,
                    precision: value.precision))
        case let .timestamp(value):
            return .timestamp(
                DatabaseTimestampValue(
                    text: redactText(value.text, maximumBytes: Self.maximumValueTextBytes),
                    timeZoneIdentifier: value.timeZoneIdentifier.map {
                        redactText($0, maximumBytes: Self.maximumValueTextBytes)
                    },
                    timeZoneOffsetMinutes: value.timeZoneOffsetMinutes,
                    precision: value.precision))
        case let .uuid(value):
            return .uuid(value)
        case let .array(values):
            return .array(
                values.prefix(Self.maximumValueCollectionElements).map {
                    sanitizeValue($0, depth: depth + 1, budget: &budget)
                })
        case let .object(fields):
            return .object(
                fields.prefix(Self.maximumValueCollectionElements).map {
                    DatabaseObjectField(
                        name: redactText(
                            $0.name,
                            maximumBytes: Self.maximumTargetSegmentBytes),
                        value: sanitizeValue(
                            $0.value,
                            depth: depth + 1,
                            budget: &budget))
                })
        case let .productSpecific(value):
            return .productSpecific(
                DatabaseProductValue(
                    product: value.product,
                    typeName: redactText(
                        value.typeName,
                        maximumBytes: Self.maximumValueTextBytes),
                    textRepresentation: value.textRepresentation.map {
                        redactText($0, maximumBytes: Self.maximumValueTextBytes)
                    },
                    binaryRepresentation: value.binaryRepresentation.flatMap(redactData),
                    attributes: value.attributes.prefix(Self.maximumProductAttributes).map {
                        DatabaseStringAttribute(
                            name: redactText(
                                $0.name,
                                maximumBytes: Self.maximumDetailNameBytes),
                            value: redactText(
                                $0.value,
                                maximumBytes: Self.maximumDetailValueBytes))
                    }))
        }
    }

    private func sanitizeBinary(_ value: DatabaseBinaryValue) -> DatabaseBinaryValue {
        switch value {
        case let .complete(data, mediaType, digest):
            guard let safeData = redactData(data) else {
                return .preview(
                    byteCount: UInt64(data.count),
                    bytes: Data(),
                    mediaType: mediaType.map {
                        redactText($0, maximumBytes: Self.maximumDetailValueBytes)
                    },
                    digest: digest.map {
                        redactText($0, maximumBytes: Self.maximumDetailValueBytes)
                    })
            }
            return .complete(
                data: safeData,
                mediaType: mediaType.map {
                    redactText($0, maximumBytes: Self.maximumDetailValueBytes)
                },
                digest: digest.map {
                    redactText($0, maximumBytes: Self.maximumDetailValueBytes)
                })
        case let .preview(byteCount, bytes, mediaType, digest):
            return .preview(
                byteCount: byteCount,
                bytes: redactData(bytes) ?? Data(),
                mediaType: mediaType.map {
                    redactText($0, maximumBytes: Self.maximumDetailValueBytes)
                },
                digest: digest.map {
                    redactText($0, maximumBytes: Self.maximumDetailValueBytes)
                })
        }
    }

    private func redactData(_ value: Data) -> Data? {
        guard value.count <= Self.maximumValueBinaryBytes, let redactor else { return nil }
        let redacted = redactor.redact(value)
        guard redacted.count <= Self.maximumValueBinaryBytes else { return nil }
        return redacted
    }

    private func redactText(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count <= maximumBytes, let redactor else {
            return Self.truncationMarker
        }
        return bounded(redactor.redact(value), maximumBytes: maximumBytes)
    }

    private func bounded(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var output = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumBytes else { break }
            output.append(character)
            byteCount += characterBytes
        }
        return output
    }

    private func countDetails(actual: Int, maximum: Int) -> [DatabaseErrorDetail] {
        [
            DatabaseErrorDetail(name: "actual", value: String(actual)),
            DatabaseErrorDetail(name: "maximum", value: String(maximum)),
        ]
    }

    private func retry(
        _ action: DatabaseRetryAction,
        _ message: String? = nil
    ) -> DatabaseRetryGuidance {
        DatabaseRetryGuidance(action: action, message: message)
    }

    private func newPreviewRetry() -> DatabaseRetryGuidance {
        retry(.createNewPreview, "Create and review a new mutation preview.")
    }

    private func opaqueMessage(for category: DatabaseErrorCategory) -> String {
        switch category {
        case .invalidRequest:
            "The database request is invalid."
        case .connectionFailed:
            "The database connection failed."
        case .authenticationFailed:
            "Database authentication failed."
        case .tlsFailed:
            "The secure database connection failed."
        case .tunnelFailed:
            "The database tunnel failed."
        case .permissionDenied:
            "The database operation is not permitted."
        case .unsupported:
            "The database operation is unsupported."
        case .readOnlyViolation:
            "The database connection is read only."
        case .confirmationRequired:
            "The database operation requires confirmation."
        case .confirmationInvalid:
            "The database confirmation is invalid."
        case .conflict:
            "The database record changed before the operation completed."
        case .timeout:
            "The database operation timed out."
        case .cancelled:
            "The database operation was cancelled."
        case .server:
            "The database server rejected the operation."
        case .network:
            "The database network request failed."
        case .decoding:
            "The database response could not be decoded."
        case .partialFailure:
            "The database operation completed with failures."
        case .resourceLimit:
            "The database operation exceeded a safety limit."
        case .internalFailure:
            "The database operation failed unexpectedly."
        }
    }

    private func defaultRetry(for category: DatabaseErrorCategory) -> DatabaseRetryGuidance {
        switch category {
        case .connectionFailed, .tlsFailed, .tunnelFailed, .network:
            retry(.reconnect, "Reconnect before retrying the operation.")
        case .authenticationFailed:
            retry(.reauthenticate, "Replace the saved credential before reconnecting.")
        case .unsupported, .permissionDenied:
            retry(
                .refreshCapabilities,
                "Refresh the connection capabilities before retrying.")
        case .confirmationRequired, .confirmationInvalid:
            newPreviewRetry()
        case .conflict, .timeout, .partialFailure:
            retry(.userDecision, "Review the result before retrying the operation.")
        case .invalidRequest, .readOnlyViolation, .cancelled, .server, .decoding,
            .resourceLimit, .internalFailure:
            retry(.none)
        }
    }
}

private struct DatabaseErrorSanitizationBudget {
    var nodes = 0
}
