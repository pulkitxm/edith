package enum DatabaseAdapterBounds {
    package static let maximumProducts = DatabaseProduct.allCases.count
    package static let maximumCapabilities = 256
    package static let maximumPermissions = 512
    package static let maximumSafetyLimitations = 100
    package static let maximumResolvedSecrets = 16
    package static let maximumSecretBytes = 1_048_576
    package static let maximumProjectionFields = 512
    package static let maximumSorts = 64
    package static let maximumContinuationBytes = 65_536
    package static let maximumPageRecords = DatabasePageSize.range.upperBound
    package static let maximumPageFields = 512
    package static let maximumRecordFields = 512
    package static let maximumPageBytes = 16_777_216
    package static let maximumStreamBatchRecords = 500
    package static let maximumStreamBatchBytes = 4_194_304
    package static let maximumWarnings = 100
    package static let maximumPartialFailures = 100
    package static let maximumServerOperationIdentifierBytes = 4_096
}
