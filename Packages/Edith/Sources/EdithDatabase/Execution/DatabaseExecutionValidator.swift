import Foundation

enum DatabaseExecutionValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(contract: String, expected: Int, actual: Int)
    case deadlineExceeded
    case invalidTarget(String)
    case emptyCommand
    case queryLanguageMismatch(language: DatabaseQueryLanguage, product: DatabaseProduct)
    case queryBodyNotAllowed(DatabaseQueryLanguage)
    case limitExceeded(name: String, actual: Int, maximum: Int)
    case encodedSizeExceeded(name: String, actual: Int, maximum: Int)
    case productMismatch(expected: DatabaseProduct, actual: DatabaseProduct)
    case capabilityUnavailable(DatabaseCapabilityID, DatabaseCapabilityUnavailableReason?)
    case invalidAdapterResult(String)
}

struct DatabaseExecutionValidator: Sendable {
    static let maximumCommandBytes = 1_048_576
    static let maximumRequestBytes = 2_097_152
    static let maximumParameterCount = 512
    static let maximumParameterNameBytes = 1_024
    static let maximumTargetPathSegments = 64
    static let maximumTargetSegmentBytes = 4_096
    static let maximumSortCount = 64
    static let maximumFieldPathSegments = 64
    static let maximumFilterDepth = 32
    static let maximumInputNodes = 10_000
    static let maximumFieldCount = 512
    static let maximumWarningCount = 100
    static let maximumPartialFailureCount = 100
    static let maximumPageBytes = 16_777_216
    static let maximumContinuationTokenBytes = 131_072

    private let currentDate: @Sendable () -> Date

    init(currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.currentDate = currentDate
    }

    func validate(_ request: DatabaseConnectionTestRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionTestRequest.schemaVersion,
            contract: "connection test request")
        try validate(request.operation)
        try Self.validateEncodedSize(request, name: "connection test request")
    }

    func validate(_ request: DatabaseCapabilitiesRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseCapabilitiesRequest.schemaVersion,
            contract: "capabilities request")
        try validate(request.operation)
        try Self.validateEncodedSize(request, name: "capabilities request")
    }

    func validate(_ request: DatabaseBrowseRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseBrowseRequest.schemaVersion,
            contract: "browse request")
        try validate(request.operation)
        try Self.validateTarget(request.target, requiresObject: true)
        try Self.validatePageRequest(request.page)
        try Self.validateEncodedSize(request, name: "browse request")
    }

    func validate(_ request: DatabaseQueryRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseQueryRequest.schemaVersion,
            contract: "query request")
        try validate(request.operation)
        try Self.validateTarget(request.target, requiresObject: false)
        guard !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseExecutionValidationError.emptyCommand
        }
        try Self.validateByteLimit(
            request.command,
            name: "query command",
            maximum: Self.maximumCommandBytes)
        guard request.parameters.count <= Self.maximumParameterCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "query parameters",
                actual: request.parameters.count,
                maximum: Self.maximumParameterCount)
        }
        for parameter in request.parameters {
            if let name = parameter.name {
                guard !name.isEmpty else {
                    throw DatabaseExecutionValidationError.invalidTarget(
                        "A named query parameter has an empty name.")
                }
                try Self.validateByteLimit(
                    name,
                    name: "query parameter name",
                    maximum: Self.maximumParameterNameBytes)
            }
        }
        var inputNodes = 0
        for parameter in request.parameters {
            try Self.validateValue(parameter.value, nodes: &inputNodes)
        }
        if let body = request.body {
            try Self.validateValue(body, nodes: &inputNodes)
        }
        try Self.validatePageRequest(request.page, nodes: &inputNodes)
        switch request.language {
        case .sql, .redisCommand, .clickHouseSQL:
            if request.body != nil {
                throw DatabaseExecutionValidationError.queryBodyNotAllowed(request.language)
            }
        case .mongoQuery, .searchQueryDSL:
            break
        }
        try Self.validateEncodedSize(request, name: "query request")
    }

    func validate(
        _ request: DatabaseQueryRequest,
        connection: DatabaseConnectionDefinition
    ) throws {
        try validate(request)
        guard request.target.connectionID == connection.id else {
            throw DatabaseExecutionValidationError.invalidTarget(
                "The query target does not belong to the selected connection.")
        }
        let matches =
            switch request.language {
            case .sql:
                connection.productHint.family == .relational
            case .redisCommand:
                connection.productHint.family == .keyValue
            case .mongoQuery:
                connection.productHint.family == .document
            case .searchQueryDSL:
                connection.productHint.family == .search
            case .clickHouseSQL:
                connection.productHint == .clickHouse
            }
        guard matches else {
            throw DatabaseExecutionValidationError.queryLanguageMismatch(
                language: request.language,
                product: connection.productHint)
        }
    }

    func validate(_ request: DatabaseMutationPreviewRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationPreviewRequest.schemaVersion,
            contract: "mutation preview request")
        try validate(request.operation)
        try Self.validateTarget(request.mutation.target, requiresObject: false)
        try Self.validateEncodedSize(request, name: "mutation preview request")
    }

    func validate(_ request: DatabaseMutationApplyRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationApplyRequest.schemaVersion,
            contract: "mutation apply request")
        try validate(request.operation)
        try Self.validateTarget(request.mutation.target, requiresObject: false)
        try Self.validateEncodedSize(request, name: "mutation apply request")
    }

    func validate(_ operation: DatabaseOperationContext) throws {
        if let deadline = operation.deadline, deadline <= currentDate() {
            throw DatabaseExecutionValidationError.deadlineExceeded
        }
    }

    func validate(
        report: DatabaseCapabilityReport,
        connection: DatabaseConnectionDefinition
    ) throws {
        guard report.productIdentity.product == connection.productHint else {
            throw DatabaseExecutionValidationError.productMismatch(
                expected: connection.productHint,
                actual: report.productIdentity.product)
        }
    }

    func require(
        _ capability: DatabaseCapabilityID,
        in report: DatabaseCapabilityReport
    ) throws {
        guard report.supports(capability) else {
            throw DatabaseExecutionValidationError.capabilityUnavailable(
                capability,
                report.unavailableReason(for: capability))
        }
    }

    func validate(
        page: DatabasePage<DatabaseRecord>,
        request: DatabasePageRequest
    ) throws {
        guard page.records.count <= request.pageSize.value else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned more records than the requested page size.")
        }
        guard page.fields.count <= Self.maximumFieldCount else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many field descriptors.")
        }
        guard page.metadata.warnings.count <= Self.maximumWarningCount else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many warnings.")
        }
        guard page.metadata.partialFailures.count <= Self.maximumPartialFailureCount else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many partial failures.")
        }
        if let continuation = page.nextContinuation {
            guard continuation.rawValue.utf8.count <= Self.maximumContinuationTokenBytes else {
                throw DatabaseExecutionValidationError.invalidAdapterResult(
                    "The adapter returned an oversized continuation token.")
            }
        }
        let encoded = try JSONEncoder().encode(page)
        guard encoded.count <= Self.maximumPageBytes else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned an oversized page.")
        }
    }

    private static func validateVersion(
        _ actual: Int,
        expected: Int,
        contract: String
    ) throws {
        guard actual == expected else {
            throw DatabaseExecutionValidationError.unsupportedVersion(
                contract: contract,
                expected: expected,
                actual: actual)
        }
    }

    private static func validateTarget(
        _ target: DatabaseTargetIdentifier,
        requiresObject: Bool
    ) throws {
        if requiresObject, target.object == nil {
            throw DatabaseExecutionValidationError.invalidTarget(
                "The operation requires a database object target.")
        }
        guard let object = target.object else { return }
        guard !object.path.isEmpty else {
            throw DatabaseExecutionValidationError.invalidTarget(
                "The target object path is empty.")
        }
        guard object.path.count <= maximumTargetPathSegments else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "target path segments",
                actual: object.path.count,
                maximum: maximumTargetPathSegments)
        }
        for segment in object.path {
            guard !segment.isEmpty else {
                throw DatabaseExecutionValidationError.invalidTarget(
                    "The target object path contains an empty segment.")
            }
            try validateByteLimit(
                segment,
                name: "target path segment",
                maximum: maximumTargetSegmentBytes)
        }
    }

    private static func validatePageRequest(_ request: DatabasePageRequest) throws {
        var nodes = 0
        try validatePageRequest(request, nodes: &nodes)
    }

    private static func validatePageRequest(
        _ request: DatabasePageRequest,
        nodes: inout Int
    ) throws {
        guard request.sorts.count <= maximumSortCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "sort fields",
                actual: request.sorts.count,
                maximum: maximumSortCount)
        }
        for sort in request.sorts {
            try validateFieldPath(sort.field)
        }
        if let projection = request.projection {
            guard projection.fields.count <= maximumFieldCount else {
                throw DatabaseExecutionValidationError.limitExceeded(
                    name: "projected fields",
                    actual: projection.fields.count,
                    maximum: maximumFieldCount)
            }
            for field in projection.fields {
                try validateFieldPath(field.path)
                if let alias = field.alias {
                    try validateByteLimit(
                        alias,
                        name: "projected field alias",
                        maximum: maximumTargetSegmentBytes)
                }
            }
        }
        if let filter = request.filter {
            try validateFilter(filter, nodes: &nodes)
        }
        if let continuation = request.continuation {
            try validateByteLimit(
                continuation.rawValue,
                name: "continuation token",
                maximum: maximumContinuationTokenBytes)
        }
    }

    private static func validateFieldPath(_ path: DatabaseFieldPath) throws {
        guard !path.segments.isEmpty else {
            throw DatabaseExecutionValidationError.invalidTarget("A field path is empty.")
        }
        guard path.segments.count <= maximumFieldPathSegments else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "field path segments",
                actual: path.segments.count,
                maximum: maximumFieldPathSegments)
        }
        for segment in path.segments {
            guard !segment.isEmpty else {
                throw DatabaseExecutionValidationError.invalidTarget(
                    "A field path contains an empty segment.")
            }
            try validateByteLimit(
                segment,
                name: "field path segment",
                maximum: maximumTargetSegmentBytes)
        }
    }

    private static func validateFilter(
        _ filter: DatabaseFilter,
        nodes: inout Int
    ) throws {
        var pending = [(filter, 1)]
        while let (current, depth) = pending.popLast() {
            try consumeNode(depth: depth, nodes: &nodes)
            switch current {
            case let .predicate(predicate):
                try validateFieldPath(predicate.field)
                for value in predicate.values {
                    try validateValue(value, nodes: &nodes)
                }
            case let .all(children), let .any(children):
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            case let .not(child):
                pending.append((child, depth + 1))
            }
        }
    }

    private static func validateValue(
        _ value: DatabaseValue,
        nodes: inout Int
    ) throws {
        var pending = [(value, 1)]
        while let (current, depth) = pending.popLast() {
            try consumeNode(depth: depth, nodes: &nodes)
            switch current {
            case let .array(values):
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            case let .object(fields):
                for field in fields {
                    guard !field.name.isEmpty else {
                        throw DatabaseExecutionValidationError.invalidTarget(
                            "A database object value contains an empty field name.")
                    }
                    try validateByteLimit(
                        field.name,
                        name: "database object field name",
                        maximum: maximumTargetSegmentBytes)
                }
                pending.append(contentsOf: fields.map { ($0.value, depth + 1) })
            case .missing, .null, .boolean, .signedInteger, .unsignedInteger, .decimal,
                .floatingPoint, .string, .binary, .date, .time, .timestamp, .uuid,
                .productSpecific:
                break
            }
        }
    }

    private static func consumeNode(depth: Int, nodes: inout Int) throws {
        guard depth <= maximumFilterDepth else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "input depth",
                actual: depth,
                maximum: maximumFilterDepth)
        }
        nodes += 1
        guard nodes <= maximumInputNodes else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "input nodes",
                actual: nodes,
                maximum: maximumInputNodes)
        }
    }

    private static func validateEncodedSize<Value: Encodable>(
        _ value: Value,
        name: String
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximumRequestBytes else {
            throw DatabaseExecutionValidationError.encodedSizeExceeded(
                name: name,
                actual: encoded.count,
                maximum: maximumRequestBytes)
        }
    }

    private static func validateByteLimit(
        _ value: String,
        name: String,
        maximum: Int
    ) throws {
        let bytes = value.utf8.count
        guard bytes <= maximum else {
            throw DatabaseExecutionValidationError.encodedSizeExceeded(
                name: name,
                actual: bytes,
                maximum: maximum)
        }
    }
}
