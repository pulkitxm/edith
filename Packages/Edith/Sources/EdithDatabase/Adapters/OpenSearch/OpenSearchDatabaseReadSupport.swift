import CryptoKit
import Foundation

struct OpenSearchDatabaseSearchPlan: Sendable {
    let target: String
    let body: Data
    let requestDigest: String
    let continuation: OpenSearchDatabaseContinuationPayload?
    let aggregationOnly: Bool
}

struct OpenSearchDatabaseContinuationPayload: Codable, Hashable, Sendable {
    static let version = 1

    let schemaVersion: Int
    let sessionID: UUID
    let connectionID: DatabaseConnectionID
    let target: DatabaseTargetIdentifier
    let requestDigest: String
    let pointInTimeID: String
    let sort: [OpenSearchDatabaseJSONValue]
    let expiresAt: Date

    init(
        sessionID: DatabaseAdapterSessionID,
        connectionID: DatabaseConnectionID,
        target: DatabaseTargetIdentifier,
        requestDigest: String,
        pointInTimeID: String,
        sort: [OpenSearchDatabaseJSONValue],
        expiresAt: Date
    ) {
        schemaVersion = Self.version
        self.sessionID = sessionID.rawValue
        self.connectionID = connectionID
        self.target = target
        self.requestDigest = requestDigest
        self.pointInTimeID = pointInTimeID
        self.sort = sort
        self.expiresAt = expiresAt
    }
}

enum OpenSearchDatabaseReadCompiler {
    static let maximumPageSize = 100
    private static let continuationLifetime: TimeInterval = 50
    private static let maximumQueryNodes = 20_000
    private static let maximumQueryDepth = 32
    private static let maximumAggregations = 16
    private static let maximumAggregationDepth = 4
    private static let maximumHighlightFields = 16

    static func compileBrowse(
        _ request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        requestTimeoutMilliseconds: UInt64,
        now: Date = Date()
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseSearchPlan {
        guard request.pageSize.value <= maximumPageSize else {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        let target = try documentTarget(request.target)
        let digest = try digest(
            source: request,
            language: nil,
            command: "browse",
            parameters: [],
            queryBody: nil)
        let continuation = try continuation(
            request.continuation,
            request: request,
            sessionID: sessionID,
            digest: digest,
            now: now)
        var body = try commonBody(
            request,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds,
            continuation: continuation)
        body["query"] = try combinedQuery(
            supplied: nil,
            filter: request.filter)
        let encodedBody = try encode(body)
        return OpenSearchDatabaseSearchPlan(
            target: target,
            body: encodedBody,
            requestDigest: digest,
            continuation: continuation,
            aggregationOnly: false)
    }

    static func compileQuery(
        _ request: DatabaseAdapterQueryRequest,
        sessionID: DatabaseAdapterSessionID,
        requestTimeoutMilliseconds: UInt64,
        now: Date = Date()
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseSearchPlan {
        guard request.language == .searchQueryDSL, request.parameters.isEmpty else {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        guard request.source.pageSize.value <= maximumPageSize else {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        let aggregationOnly: Bool
        switch request.command {
        case "search":
            aggregationOnly = false
        case "aggregate":
            aggregationOnly = true
        default:
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        let target = try documentTarget(request.source.target)
        let supplied: [String: OpenSearchDatabaseJSONValue]
        if let body = request.body {
            let value: OpenSearchDatabaseJSONValue
            do {
                value = try OpenSearchDatabaseJSONValue(databaseValue: body)
            } catch {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            guard case let .object(fields) = value else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            supplied = fields
        } else {
            supplied = [:]
        }
        try validateQueryBody(supplied, aggregationOnly: aggregationOnly)
        let digest = try digest(
            source: request.source,
            language: request.language,
            command: request.command,
            parameters: request.parameters,
            queryBody: request.body)
        let continuation = try continuation(
            request.source.continuation,
            request: request.source,
            sessionID: sessionID,
            digest: digest,
            now: now)
        if aggregationOnly, continuation != nil {
            throw OpenSearchDatabaseAdapterSupport.invalidContinuation
        }
        var body = try commonBody(
            request.source,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds,
            continuation: continuation)
        body["query"] = try combinedQuery(
            supplied: supplied["query"],
            filter: request.source.filter)
        if aggregationOnly {
            guard let aggregations = supplied["aggs"] ?? supplied["aggregations"] else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            try validateAggregations(aggregations)
            body["size"] = .signedInteger(0)
            body["aggs"] = aggregations
        } else if let highlight = supplied["highlight"] {
            try validateHighlight(highlight)
            body["highlight"] = highlight
        }
        if let trackTotalHits = supplied["track_total_hits"] {
            try validateTrackTotalHits(trackTotalHits)
            body["track_total_hits"] = trackTotalHits
        }
        let encodedBody = try encode(body)
        return OpenSearchDatabaseSearchPlan(
            target: target,
            body: encodedBody,
            requestDigest: digest,
            continuation: continuation,
            aggregationOnly: aggregationOnly)
    }

    static func nextContinuation(
        sessionID: DatabaseAdapterSessionID,
        request: DatabaseAdapterPageRequest,
        digest: String,
        pointInTimeID: String,
        sort: [OpenSearchDatabaseJSONValue],
        now: Date = Date()
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterContinuation {
        guard OpenSearchDatabaseDriverSupport.validOpaqueIdentifier(pointInTimeID),
            !sort.isEmpty,
            sort.count <= DatabaseAdapterBounds.maximumSorts + 1,
            sort.allSatisfy({ $0.isBoundedScalar() })
        else {
            throw OpenSearchDatabaseAdapterSupport.invalidResponse
        }
        let expiresAt = now.addingTimeInterval(continuationLifetime)
        let value = OpenSearchDatabaseContinuationPayload(
            sessionID: sessionID,
            connectionID: request.target.connectionID,
            target: request.target,
            requestDigest: digest,
            pointInTimeID: pointInTimeID,
            sort: sort,
            expiresAt: expiresAt)
        let payload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            payload = try encoder.encode(value)
        } catch {
            throw OpenSearchDatabaseAdapterSupport.invalidResponse
        }
        return try DatabaseAdapterContinuation(
            mode: .pointInTime,
            payload: payload,
            expiresAt: expiresAt)
    }

    static func fieldDescriptors(
        _ response: OpenSearchDatabaseMappingResponse
    ) throws(DatabaseAdapterFailure) -> [DatabaseFieldDescriptor] {
        var descriptors: [DatabaseFieldDescriptor] = []
        for index in response.indices.keys.sorted() {
            guard let mapping = response.indices[index]?.mappings else { continue }
            try appendFields(
                mapping.properties ?? [:],
                prefix: [],
                descriptors: &descriptors)
            try appendFields(
                mapping.runtime ?? [:],
                prefix: [],
                descriptors: &descriptors,
                runtime: true)
            try appendFields(
                mapping.derived ?? [:],
                prefix: [],
                descriptors: &descriptors,
                derived: true)
        }
        var unique: [DatabaseFieldPath: DatabaseFieldDescriptor] = [:]
        for descriptor in descriptors {
            unique[descriptor.path] = descriptor
        }
        let sorted = unique.values.sorted {
            $0.path.segments.joined(separator: ".")
                < $1.path.segments.joined(separator: ".")
        }
        guard sorted.count <= DatabaseAdapterBounds.maximumPageFields else {
            throw .limitExceeded(
                limit: .pageFields,
                actual: sorted.count,
                maximum: DatabaseAdapterBounds.maximumPageFields)
        }
        return sorted
    }

    static func discoveryPage(
        response: OpenSearchDatabaseResolveResponse,
        request: DatabaseAdapterPageRequest,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        var records: [DatabaseRecord] = []
        records.reserveCapacity(
            response.indices.count + response.aliases.count + response.dataStreams.count)
        for index in response.indices {
            records.append(
                discoveryRecord(
                    kind: .index,
                    name: index.name,
                    fields: [
                        DatabaseObjectField(
                            name: "aliases",
                            value: .array(index.aliases.sorted().map(DatabaseValue.string))),
                        DatabaseObjectField(
                            name: "attributes",
                            value: .array(index.attributes.sorted().map(DatabaseValue.string))),
                        DatabaseObjectField(
                            name: "dataStream",
                            value: index.dataStream.map(DatabaseValue.string) ?? .null),
                        DatabaseObjectField(
                            name: "mode",
                            value: index.mode.map(DatabaseValue.string) ?? .null),
                    ]))
        }
        for alias in response.aliases {
            records.append(
                discoveryRecord(
                    kind: .alias,
                    name: alias.name,
                    fields: [
                        DatabaseObjectField(
                            name: "indices",
                            value: .array(alias.indices.sorted().map(DatabaseValue.string)))
                    ]))
        }
        for stream in response.dataStreams {
            records.append(
                discoveryRecord(
                    kind: .dataStream,
                    name: stream.name,
                    fields: [
                        DatabaseObjectField(
                            name: "backingIndices",
                            value: .array(stream.backingIndices.sorted().map(DatabaseValue.string))),
                        DatabaseObjectField(
                            name: "timestampField",
                            value: .string(stream.timestampField)),
                    ]))
        }
        records.sort {
            let lhs = $0.identity?.components.first?.value
            let rhs = $1.identity?.components.first?.value
            return String(describing: lhs) < String(describing: rhs)
        }
        let total = records.count
        let returned = Array(records.prefix(request.pageSize.value))
        let truncated = returned.count < total
        let warning =
            truncated
            ? [
                DatabaseWarning(
                    code: "opensearch.discovery.truncated",
                    message: "Index discovery was truncated to the requested page size.",
                    severity: .caution,
                    target: request.target)
            ] : []
        return try DatabaseAdapterPage(
            records: returned,
            fields: discoveryFields,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: truncated ? .truncated : .complete,
                    reason: truncated ? "More index metadata is available." : nil),
                count: DatabaseCountMetadata(value: UInt64(total), accuracy: .exact),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: elapsedMilliseconds(since: startedAt)),
                warnings: warning))
    }

    static func permissionDegradedDiscoveryPage(
        request: DatabaseAdapterPageRequest,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try DatabaseAdapterPage(
            records: [],
            fields: discoveryFields,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: .partial,
                    reason: "Index metadata permission is unavailable."),
                count: DatabaseCountMetadata(accuracy: .unknown),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: elapsedMilliseconds(since: startedAt)),
                warnings: [
                    DatabaseWarning(
                        code: "opensearch.metadata.permission",
                        message: "OpenSearch denied index metadata discovery.",
                        severity: .caution,
                        target: request.target)
                ]))
    }

    static func documentTarget(_ target: DatabaseTargetIdentifier) throws(DatabaseAdapterFailure)
        -> String
    {
        guard target.record == nil,
            let object = target.object,
            [.index, .alias, .dataStream].contains(object.kind),
            object.path.count == 1,
            object.nativeIdentifier == nil,
            let value = object.path.first,
            OpenSearchDatabaseDriverSupport.validTargetName(value)
        else {
            throw OpenSearchDatabaseAdapterSupport.invalidTarget
        }
        return value
    }

    static func isDiscoveryTarget(_ target: DatabaseTargetIdentifier) -> Bool {
        guard target.record == nil, let object = target.object, object.kind == .server,
            object.nativeIdentifier == nil
        else {
            return false
        }
        return object.path.isEmpty || object.path == ["indices"]
    }

    static func elapsedMilliseconds(
        since instant: ContinuousClock.Instant
    ) -> UInt64 {
        let duration = ContinuousClock.now - instant
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let milliseconds = UInt64(seconds) * 1_000
        return milliseconds + UInt64(attoseconds / 1_000_000_000_000_000)
    }

    private static let discoveryFields = [
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("kind"),
            displayName: "kind",
            typeName: "object_kind",
            isNullable: false,
            isSortable: true,
            isFilterable: true),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("name"),
            displayName: "name",
            typeName: "keyword",
            isNullable: false,
            isSortable: true,
            isFilterable: true),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("metadata"),
            displayName: "metadata",
            typeName: "object",
            isNullable: true,
            isSortable: false,
            isFilterable: false),
    ]

    private static func continuation(
        _ continuation: DatabaseAdapterContinuation?,
        request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        digest: String,
        now: Date
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseContinuationPayload? {
        guard let continuation else { return nil }
        guard continuation.mode == .pointInTime,
            continuation.expiresAt.map({ $0 > now }) ?? false
        else {
            throw OpenSearchDatabaseAdapterSupport.invalidContinuation
        }
        let value: OpenSearchDatabaseContinuationPayload
        do {
            value = try JSONDecoder().decode(
                OpenSearchDatabaseContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw OpenSearchDatabaseAdapterSupport.invalidContinuation
        }
        guard value.schemaVersion == OpenSearchDatabaseContinuationPayload.version,
            value.sessionID == sessionID.rawValue,
            value.connectionID == request.target.connectionID,
            value.target == request.target,
            value.requestDigest == digest,
            value.expiresAt > now,
            continuation.expiresAt == value.expiresAt,
            OpenSearchDatabaseDriverSupport.validOpaqueIdentifier(value.pointInTimeID),
            !value.sort.isEmpty,
            value.sort.count <= DatabaseAdapterBounds.maximumSorts + 1,
            value.sort.allSatisfy({ $0.isBoundedScalar() })
        else {
            throw OpenSearchDatabaseAdapterSupport.invalidContinuation
        }
        return value
    }

    private static func commonBody(
        _ request: DatabaseAdapterPageRequest,
        requestTimeoutMilliseconds: UInt64,
        continuation: OpenSearchDatabaseContinuationPayload?
    ) throws(DatabaseAdapterFailure) -> [String: OpenSearchDatabaseJSONValue] {
        guard request.consistency != .strong else {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        var body: [String: OpenSearchDatabaseJSONValue] = [
            "size": .signedInteger(Int64(request.pageSize.value + 1)),
            "track_total_hits": .signedInteger(10_000),
            "timeout": .string(String(requestTimeoutMilliseconds) + "ms"),
            "pit": .object([
                "id": .string(continuation?.pointInTimeID ?? ""),
                "keep_alive": .string("60s"),
            ]),
            "sort": .array(try sorts(request.sorts)),
        ]
        if let continuation {
            body["search_after"] = .array(continuation.sort)
        }
        if let projection = request.projection {
            body["_source"] = try sourceProjection(projection)
        }
        return body
    }

    private static func combinedQuery(
        supplied: OpenSearchDatabaseJSONValue?,
        filter: DatabaseFilter?
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseJSONValue {
        let supplied = supplied ?? .object(["match_all": .object([:])])
        guard let filter else { return supplied }
        return .object([
            "bool": .object([
                "must": .array([supplied]),
                "filter": .array([try query(filter, depth: 0)]),
            ])
        ])
    }

    private static func query(
        _ filter: DatabaseFilter,
        depth: Int
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseJSONValue {
        guard depth <= 16 else { throw OpenSearchDatabaseAdapterSupport.invalidRequest }
        switch filter {
        case let .predicate(predicate):
            return try query(predicate)
        case let .all(children):
            guard !children.isEmpty, children.count <= 64 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            var clauses: [OpenSearchDatabaseJSONValue] = []
            clauses.reserveCapacity(children.count)
            for child in children {
                clauses.append(try query(child, depth: depth + 1))
            }
            return .object([
                "bool": .object([
                    "filter": .array(clauses)
                ])
            ])
        case let .any(children):
            guard !children.isEmpty, children.count <= 64 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            var clauses: [OpenSearchDatabaseJSONValue] = []
            clauses.reserveCapacity(children.count)
            for child in children {
                clauses.append(try query(child, depth: depth + 1))
            }
            return .object([
                "bool": .object([
                    "should": .array(clauses),
                    "minimum_should_match": .signedInteger(1),
                ])
            ])
        case let .not(child):
            return .object([
                "bool": .object([
                    "must_not": .array([try query(child, depth: depth + 1)])
                ])
            ])
        }
    }

    private static func query(
        _ predicate: DatabaseFilterPredicate
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseJSONValue {
        let field = try fieldName(predicate.field)
        var values: [OpenSearchDatabaseJSONValue] = []
        values.reserveCapacity(predicate.values.count)
        do {
            for value in predicate.values {
                values.append(try OpenSearchDatabaseJSONValue(databaseValue: value))
            }
        } catch {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        let insensitive = predicate.caseSensitivity == .insensitive
        let term: (OpenSearchDatabaseJSONValue) -> OpenSearchDatabaseJSONValue = { value in
            var options: [String: OpenSearchDatabaseJSONValue] = ["value": value]
            if insensitive { options["case_insensitive"] = .boolean(true) }
            return .object(["term": .object([field: .object(options)])])
        }
        switch predicate.operation {
        case .equal:
            guard values.count == 1 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            return term(values[0])
        case .notEqual:
            guard values.count == 1 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            return .object(["bool": .object(["must_not": .array([term(values[0])])])])
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            guard values.count == 1 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            let operation =
                switch predicate.operation {
                case .greaterThan: "gt"
                case .greaterThanOrEqual: "gte"
                case .lessThan: "lt"
                default: "lte"
                }
            return .object([
                "range": .object([field: .object([operation: values[0]])])
            ])
        case .in, .notIn:
            guard !values.isEmpty, values.count <= 1_000 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            let terms = OpenSearchDatabaseJSONValue.object([
                "terms": .object([field: .array(values)])
            ])
            if predicate.operation == .notIn {
                return .object(["bool": .object(["must_not": .array([terms])])])
            }
            return terms
        case .between:
            guard values.count == 2 else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            return .object([
                "range": .object([field: .object(["gte": values[0], "lte": values[1]])])
            ])
        case .isMissing, .isNull:
            guard values.isEmpty else { throw OpenSearchDatabaseAdapterSupport.invalidRequest }
            let exists = OpenSearchDatabaseJSONValue.object([
                "exists": .object(["field": .string(field)])
            ])
            return .object(["bool": .object(["must_not": .array([exists])])])
        case .isNotMissing, .isNotNull:
            guard values.isEmpty else { throw OpenSearchDatabaseAdapterSupport.invalidRequest }
            return .object(["exists": .object(["field": .string(field)])])
        case .fullText:
            guard values.count == 1, case let .string(value) = values[0] else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            return .object(["match": .object([field: .string(value)])])
        case .contains, .startsWith, .endsWith, .regularExpression:
            guard values.count == 1, case let .string(value) = values[0],
                value.utf8.count <= 256
            else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            let pattern =
                switch predicate.operation {
                case .contains: "*" + escapedWildcard(value) + "*"
                case .startsWith: escapedWildcard(value) + "*"
                case .endsWith: "*" + escapedWildcard(value)
                default: value
                }
            let clause = predicate.operation == .regularExpression ? "regexp" : "wildcard"
            var options: [String: OpenSearchDatabaseJSONValue] = ["value": .string(pattern)]
            if insensitive { options["case_insensitive"] = .boolean(true) }
            if clause == "regexp" { options["max_determinized_states"] = .signedInteger(10_000) }
            return .object([clause: .object([field: .object(options)])])
        }
    }

    private static func sorts(
        _ sorts: [DatabaseSort]
    ) throws(DatabaseAdapterFailure) -> [OpenSearchDatabaseJSONValue] {
        var values: [OpenSearchDatabaseJSONValue] = []
        values.reserveCapacity(sorts.count + 1)
        for sort in sorts {
            let field = try fieldName(sort.field)
            guard field != "_id", field != "_shard_doc" else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            var options: [String: OpenSearchDatabaseJSONValue] = [
                "order": .string(sort.direction == .ascending ? "asc" : "desc")
            ]
            switch sort.nullPlacement {
            case .productDefault:
                break
            case .first:
                options["missing"] = .string("_first")
            case .last:
                options["missing"] = .string("_last")
            }
            values.append(.object([field: .object(options)]))
        }
        values.append(.object(["_shard_doc": .string("asc")]))
        return values
    }

    private static func sourceProjection(
        _ projection: DatabaseProjection
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseJSONValue {
        guard !projection.fields.isEmpty else {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        var fields: [OpenSearchDatabaseJSONValue] = []
        fields.reserveCapacity(projection.fields.count)
        for projected in projection.fields {
            guard projected.alias == nil else {
                throw OpenSearchDatabaseAdapterSupport.invalidRequest
            }
            fields.append(.string(try fieldName(projected.path)))
        }
        return .object([
            projection.mode == .include ? "includes" : "excludes": .array(fields)
        ])
    }

    private static func validateQueryBody(
        _ body: [String: OpenSearchDatabaseJSONValue],
        aggregationOnly: Bool
    ) throws(DatabaseAdapterFailure) {
        let allowed: Set<String> =
            aggregationOnly
            ? ["query", "aggs", "aggregations", "track_total_hits"]
            : ["query", "highlight", "track_total_hits"]
        guard Set(body.keys).isSubset(of: allowed),
            !(body["aggs"] != nil && body["aggregations"] != nil)
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let query = body["query"] {
            var nodes = 0
            try validateQueryClause(query, depth: 0, nodes: &nodes)
        }
    }

    private static func validateQueryClause(
        _ value: OpenSearchDatabaseJSONValue,
        depth: Int,
        nodes: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard depth <= maximumQueryDepth,
            nodes < maximumQueryNodes,
            case let .object(query) = value,
            query.count == 1,
            let type = query.keys.first,
            let configuration = query[type]
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        nodes += 1
        switch type {
        case "match_all":
            try validateMatchAll(configuration)
        case "bool":
            try validateBooleanQuery(configuration, depth: depth, nodes: &nodes)
        case "constant_score":
            try validateConstantScore(configuration, depth: depth, nodes: &nodes)
        case "dis_max":
            try validateDisjunction(configuration, depth: depth, nodes: &nodes)
        case "nested":
            try validateNestedQuery(configuration, depth: depth, nodes: &nodes)
        case "exists":
            try validateExistsQuery(configuration)
        case "term", "prefix", "wildcard", "regexp":
            try validateSingleFieldQuery(type: type, configuration: configuration)
        case "terms":
            try validateTermsQuery(configuration)
        case "range":
            try validateRangeQuery(configuration)
        case "match", "match_phrase":
            try validateMatchQuery(type: type, configuration: configuration)
        case "multi_match":
            try validateMultiMatchQuery(configuration)
        default:
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func validateMatchAll(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["boost"])
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateBooleanQuery(
        _ value: OpenSearchDatabaseJSONValue,
        depth: Int,
        nodes: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            !configuration.isEmpty,
            Set(configuration.keys).isSubset(
                of: [
                    "must", "filter", "should", "must_not", "minimum_should_match", "boost",
                    "adjust_pure_negative",
                ])
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        var clauseCount = 0
        for name in ["must", "filter", "should", "must_not"] {
            guard let clause = configuration[name] else { continue }
            let clauses: [OpenSearchDatabaseJSONValue]
            if case let .array(values) = clause {
                guard !values.isEmpty, values.count <= 64 else {
                    throw OpenSearchDatabaseAdapterSupport.unsafeRequest
                }
                clauses = values
            } else {
                clauses = [clause]
            }
            clauseCount += clauses.count
            guard clauseCount <= 64 else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            for child in clauses {
                try validateQueryClause(child, depth: depth + 1, nodes: &nodes)
            }
        }
        guard clauseCount > 0 else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let minimumShouldMatch = configuration["minimum_should_match"] {
            try validateMinimumShouldMatch(minimumShouldMatch)
        }
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
        if let adjust = configuration["adjust_pure_negative"], case .boolean = adjust {
        } else if configuration["adjust_pure_negative"] != nil {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func validateConstantScore(
        _ value: OpenSearchDatabaseJSONValue,
        depth: Int,
        nodes: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["filter", "boost"]),
            let filter = configuration["filter"]
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        try validateQueryClause(filter, depth: depth + 1, nodes: &nodes)
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateDisjunction(
        _ value: OpenSearchDatabaseJSONValue,
        depth: Int,
        nodes: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["queries", "tie_breaker", "boost"]),
            case let .array(queries)? = configuration["queries"],
            !queries.isEmpty,
            queries.count <= 64
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        for query in queries {
            try validateQueryClause(query, depth: depth + 1, nodes: &nodes)
        }
        if let tieBreaker = configuration["tie_breaker"] {
            try validateFiniteNumber(tieBreaker, minimum: 0, maximum: 1)
        }
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateNestedQuery(
        _ value: OpenSearchDatabaseJSONValue,
        depth: Int,
        nodes: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["path", "query", "score_mode", "ignore_unmapped"]
            ),
            case let .string(path)? = configuration["path"],
            validFieldName(path),
            let query = configuration["query"]
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let scoreMode = configuration["score_mode"] {
            guard case let .string(value) = scoreMode,
                ["avg", "max", "min", "none", "sum"].contains(value)
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let ignoreUnmapped = configuration["ignore_unmapped"], case .boolean = ignoreUnmapped {
        } else if configuration["ignore_unmapped"] != nil {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        try validateQueryClause(query, depth: depth + 1, nodes: &nodes)
    }

    private static func validateExistsQuery(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["field", "boost"]),
            case let .string(field)? = configuration["field"],
            validFieldName(field)
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateSingleFieldQuery(
        type: String,
        configuration: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(fields) = configuration,
            fields.count == 1,
            let field = fields.keys.first,
            validFieldName(field),
            let value = fields[field]
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if value.isBoundedScalar(maximumStringBytes: 4_096) {
            return
        }
        guard case let .object(options) = value else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        let allowed: Set<String>
        switch type {
        case "term":
            allowed = ["value", "boost", "case_insensitive"]
        case "prefix", "wildcard":
            allowed = ["value", "boost", "case_insensitive"]
        case "regexp":
            allowed = ["value", "boost", "case_insensitive", "flags", "max_determinized_states"]
        default:
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        guard Set(options.keys).isSubset(of: allowed),
            let queryValue = options["value"],
            queryValue.isBoundedScalar(maximumStringBytes: 4_096)
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if type != "term" {
            guard case let .string(pattern) = queryValue,
                pattern.utf8.count <= 256,
                !pattern.contains("\0")
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let boost = options["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
        if let insensitive = options["case_insensitive"], case .boolean = insensitive {
        } else if options["case_insensitive"] != nil {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let flags = options["flags"] {
            guard case let .string(value) = flags,
                value.utf8.count <= 128,
                !value.contains("\0")
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let states = options["max_determinized_states"] {
            guard case let .signedInteger(value) = states, (1...10_000).contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateTermsQuery(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        let fields = configuration.keys.filter { $0 != "boost" }
        guard fields.count == 1,
            let field = fields.first,
            validFieldName(field),
            case let .array(values)? = configuration[field],
            !values.isEmpty,
            values.count <= 1_000,
            values.allSatisfy({ $0.isBoundedScalar(maximumStringBytes: 4_096) })
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateRangeQuery(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(fields) = value,
            fields.count == 1,
            let field = fields.keys.first,
            validFieldName(field),
            case let .object(configuration)? = fields[field],
            !configuration.isEmpty,
            Set(configuration.keys).isSubset(
                of: ["gt", "gte", "lt", "lte", "format", "time_zone", "boost"]),
            configuration.keys.contains(where: { ["gt", "gte", "lt", "lte"].contains($0) })
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        for key in ["gt", "gte", "lt", "lte"] {
            if let bound = configuration[key],
                !bound.isBoundedScalar(maximumStringBytes: 4_096)
            {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        for key in ["format", "time_zone"] {
            guard let option = configuration[key] else { continue }
            guard case let .string(value) = option,
                value.utf8.count <= 256,
                !value.contains("\0")
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let boost = configuration["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateMatchQuery(
        type: String,
        configuration: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(fields) = configuration,
            fields.count == 1,
            let field = fields.keys.first,
            validFieldName(field),
            let value = fields[field]
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if value.isBoundedScalar(maximumStringBytes: 4_096) {
            return
        }
        guard case let .object(options) = value else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        let allowed: Set<String> =
            type == "match"
            ? [
                "query", "operator", "minimum_should_match", "fuzziness", "prefix_length",
                "max_expansions", "fuzzy_transpositions", "lenient", "zero_terms_query", "boost",
            ]
            : ["query", "slop", "zero_terms_query", "boost"]
        guard Set(options.keys).isSubset(of: allowed),
            let query = options["query"],
            query.isBoundedScalar(maximumStringBytes: 4_096)
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        try validateTextQueryOptions(options)
    }

    private static func validateMultiMatchQuery(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(
                of: [
                    "query", "fields", "type", "operator", "minimum_should_match", "fuzziness",
                    "prefix_length", "max_expansions", "fuzzy_transpositions", "lenient",
                    "zero_terms_query", "tie_breaker", "boost",
                ]),
            let query = configuration["query"],
            query.isBoundedScalar(maximumStringBytes: 4_096),
            case let .array(fields)? = configuration["fields"],
            !fields.isEmpty,
            fields.count <= 16,
            fields.allSatisfy({ value in
                guard case let .string(field) = value else { return false }
                let name = field.split(separator: "^", maxSplits: 1).first.map(String.init) ?? ""
                return validFieldName(name) && field.utf8.count <= 4_096
            })
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let type = configuration["type"] {
            guard case let .string(value) = type,
                ["best_fields", "cross_fields", "most_fields", "phrase", "phrase_prefix"].contains(
                    value)
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        try validateTextQueryOptions(configuration)
        if let tieBreaker = configuration["tie_breaker"] {
            try validateFiniteNumber(tieBreaker, minimum: 0, maximum: 1)
        }
    }

    private static func validateTextQueryOptions(
        _ options: [String: OpenSearchDatabaseJSONValue]
    ) throws(DatabaseAdapterFailure) {
        if let operation = options["operator"] {
            guard case let .string(value) = operation, ["and", "or"].contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let minimumShouldMatch = options["minimum_should_match"] {
            try validateMinimumShouldMatch(minimumShouldMatch)
        }
        if let fuzziness = options["fuzziness"] {
            switch fuzziness {
            case let .signedInteger(value):
                guard (0...2).contains(value) else {
                    throw OpenSearchDatabaseAdapterSupport.unsafeRequest
                }
            case let .string(value):
                guard value == "AUTO" else {
                    throw OpenSearchDatabaseAdapterSupport.unsafeRequest
                }
            default:
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        for key in ["prefix_length", "slop"] {
            guard let option = options[key] else { continue }
            guard case let .signedInteger(value) = option, (0...64).contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let expansions = options["max_expansions"] {
            guard case let .signedInteger(value) = expansions, (1...100).contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        for key in ["fuzzy_transpositions", "lenient"] {
            guard let option = options[key] else { continue }
            guard case .boolean = option else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let zeroTerms = options["zero_terms_query"] {
            guard case let .string(value) = zeroTerms, ["all", "none"].contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let boost = options["boost"] {
            try validateFiniteNumber(boost, minimum: 0, maximum: 1_000_000)
        }
    }

    private static func validateMinimumShouldMatch(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        switch value {
        case let .signedInteger(value):
            guard (0...64).contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        case let .string(value):
            guard value.utf8.count <= 64,
                !value.isEmpty,
                !value.contains("\0"),
                value.unicodeScalars.allSatisfy({
                    CharacterSet(charactersIn: "0123456789-%< ").contains($0)
                })
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        default:
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func validateFiniteNumber(
        _ value: OpenSearchDatabaseJSONValue,
        minimum: Double,
        maximum: Double
    ) throws(DatabaseAdapterFailure) {
        let number: Double
        switch value {
        case let .signedInteger(value):
            number = Double(value)
        case let .unsignedInteger(value):
            number = Double(value)
        case let .floatingPoint(value):
            number = value
        default:
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        guard number.isFinite, (minimum...maximum).contains(number) else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func validFieldName(_ value: String) -> Bool {
        let path = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.count <= 32 else { return false }
        return path.allSatisfy { component in
            !component.isEmpty
                && component.utf8.count <= 4_096
                && !component.contains("\0")
                && !component.contains("*")
                && !component.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
        }
    }

    private static func validateAggregations(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(aggregations) = value,
            !aggregations.isEmpty,
            aggregations.count <= maximumAggregations
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        var count = 0
        try validateAggregationObject(aggregations, depth: 0, count: &count)
    }

    private static func validateAggregationObject(
        _ aggregations: [String: OpenSearchDatabaseJSONValue],
        depth: Int,
        count: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard depth <= maximumAggregationDepth else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        for (name, aggregation) in aggregations {
            guard OpenSearchDatabaseDriverSupport.validTargetName(name),
                case let .object(configuration) = aggregation
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            count += 1
            guard count <= maximumAggregations else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            guard !(configuration["aggs"] != nil && configuration["aggregations"] != nil) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            let nested = configuration["aggs"] ?? configuration["aggregations"]
            if let nested {
                guard case let .object(children) = nested else {
                    throw OpenSearchDatabaseAdapterSupport.unsafeRequest
                }
                try validateAggregationObject(children, depth: depth + 1, count: &count)
            }
            let types = configuration.keys.filter { $0 != "aggs" && $0 != "aggregations" }
            guard types.count == 1,
                let type = types.first,
                let options = configuration[type]
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            switch type {
            case "avg", "sum", "min", "max", "stats", "value_count", "cardinality":
                try validateMetricAggregation(type: type, value: options)
            case "terms":
                try validateTermsAggregation(options)
            case "date_histogram", "histogram":
                try validateHistogramAggregation(type: type, value: options)
            case "range", "date_range":
                try validateRangeAggregation(type: type, value: options)
            case "filter":
                var nodes = 0
                try validateQueryClause(options, depth: 0, nodes: &nodes)
            case "nested", "reverse_nested":
                try validateNestedAggregation(type: type, value: options)
            default:
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateMetricAggregation(
        type: String,
        value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["field", "missing", "precision_threshold"]),
            case let .string(field)? = configuration["field"],
            validFieldName(field),
            configuration["missing"]?.isBoundedScalar(maximumStringBytes: 4_096) ?? true
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if let threshold = configuration["precision_threshold"] {
            guard type == "cardinality",
                case let .signedInteger(value) = threshold,
                (0...40_000).contains(value)
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateTermsAggregation(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(
                of: ["field", "size", "shard_size", "min_doc_count", "missing", "order"]),
            case let .string(field)? = configuration["field"],
            validFieldName(field),
            configuration["missing"]?.isBoundedScalar(maximumStringBytes: 4_096) ?? true
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        try validateIntegerOption(configuration["size"], minimum: 1, maximum: 100)
        try validateIntegerOption(configuration["shard_size"], minimum: 1, maximum: 1_000)
        try validateIntegerOption(configuration["min_doc_count"], minimum: 0, maximum: Int64.max)
        if let order = configuration["order"] {
            guard case let .object(value) = order,
                value.count == 1,
                let name = value.keys.first,
                ["_count", "_key"].contains(name),
                case let .string(direction)? = value[name],
                ["asc", "desc"].contains(direction)
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateHistogramAggregation(
        type: String,
        value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        let allowed: Set<String> =
            type == "date_histogram"
            ? [
                "field", "calendar_interval", "fixed_interval", "min_doc_count", "time_zone",
                "format",
            ]
            : ["field", "interval", "min_doc_count", "offset"]
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: allowed),
            case let .string(field)? = configuration["field"],
            validFieldName(field)
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        try validateIntegerOption(configuration["min_doc_count"], minimum: 0, maximum: Int64.max)
        if type == "date_histogram" {
            let intervals = [configuration["calendar_interval"], configuration["fixed_interval"]]
                .compactMap { $0 }
            guard intervals.count == 1 else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            for option in intervals
                + [configuration["time_zone"], configuration["format"]]
                .compactMap({ $0 })
            {
                guard case let .string(value) = option,
                    !value.isEmpty,
                    value.utf8.count <= 256,
                    !value.contains("\0")
                else {
                    throw OpenSearchDatabaseAdapterSupport.unsafeRequest
                }
            }
        } else {
            guard let interval = configuration["interval"] else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            try validateFiniteNumber(interval, minimum: Double.leastNonzeroMagnitude, maximum: 1e18)
            if let offset = configuration["offset"] {
                try validateFiniteNumber(offset, minimum: -1e18, maximum: 1e18)
            }
        }
    }

    private static func validateRangeAggregation(
        type: String,
        value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        let allowed: Set<String> =
            type == "date_range"
            ? ["field", "ranges", "format", "time_zone", "keyed"]
            : ["field", "ranges", "keyed"]
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: allowed),
            case let .string(field)? = configuration["field"],
            validFieldName(field),
            case let .array(ranges)? = configuration["ranges"],
            !ranges.isEmpty,
            ranges.count <= 100
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        for range in ranges {
            guard case let .object(configuration) = range,
                !configuration.isEmpty,
                Set(configuration.keys).isSubset(of: ["from", "to", "key"]),
                configuration["from"]?.isBoundedScalar(maximumStringBytes: 4_096) ?? true,
                configuration["to"]?.isBoundedScalar(maximumStringBytes: 4_096) ?? true,
                configuration["from"] != nil || configuration["to"] != nil
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            if let key = configuration["key"] {
                guard case let .string(value) = key,
                    value.utf8.count <= 256,
                    !value.contains("\0")
                else {
                    throw OpenSearchDatabaseAdapterSupport.unsafeRequest
                }
            }
        }
        if let keyed = configuration["keyed"], case .boolean = keyed {
        } else if configuration["keyed"] != nil {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        for key in ["format", "time_zone"] {
            guard let option = configuration[key] else { continue }
            guard case let .string(value) = option,
                !value.isEmpty,
                value.utf8.count <= 256,
                !value.contains("\0")
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateNestedAggregation(
        type: String,
        value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        if type == "reverse_nested" {
            guard Set(configuration.keys).isSubset(of: ["path"]),
                configuration["path"].map({ option in
                    guard case let .string(path) = option else { return false }
                    return validFieldName(path)
                }) ?? true
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        } else {
            guard Set(configuration.keys) == ["path"],
                case let .string(path)? = configuration["path"],
                validFieldName(path)
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateIntegerOption(
        _ value: OpenSearchDatabaseJSONValue?,
        minimum: Int64,
        maximum: Int64
    ) throws(DatabaseAdapterFailure) {
        guard let value else { return }
        guard case let .signedInteger(value) = value,
            (minimum...maximum).contains(value)
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func validateHighlight(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["fields", "number_of_fragments", "fragment_size"]
            ),
            case let .object(fields)? = configuration["fields"],
            !fields.isEmpty,
            fields.count <= maximumHighlightFields
        else {
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
        for (name, value) in fields {
            guard
                (try? fieldName(DatabaseFieldPath(name.split(separator: ".").map(String.init))))
                    != nil,
                case let .object(options) = value,
                Set(options.keys).isSubset(of: ["number_of_fragments", "fragment_size"])
            else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
            try validateHighlightLimits(options)
        }
        try validateHighlightLimits(configuration)
    }

    private static func validateHighlightLimits(
        _ configuration: [String: OpenSearchDatabaseJSONValue]
    ) throws(DatabaseAdapterFailure) {
        if let fragments = configuration["number_of_fragments"] {
            guard case let .signedInteger(value) = fragments, (0...5).contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let size = configuration["fragment_size"] {
            guard case let .signedInteger(value) = size, (1...1_024).contains(value) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateTrackTotalHits(
        _ value: OpenSearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        switch value {
        case .boolean:
            return
        case let .signedInteger(limit):
            guard (0...100_000).contains(limit) else {
                throw OpenSearchDatabaseAdapterSupport.unsafeRequest
            }
        default:
            throw OpenSearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func appendFields(
        _ fields: [String: OpenSearchDatabaseMappingResponse.Field],
        prefix: [String],
        descriptors: inout [DatabaseFieldDescriptor],
        runtime: Bool = false,
        derived: Bool = false,
        insideNested: Bool = false
    ) throws(DatabaseAdapterFailure) {
        for name in fields.keys.sorted() {
            guard let field = fields[name],
                !name.isEmpty,
                name.utf8.count <= 4_096,
                !name.contains("\0")
            else {
                throw OpenSearchDatabaseAdapterSupport.invalidResponse
            }
            let path = prefix + [name]
            guard path.count <= 32 else {
                throw OpenSearchDatabaseAdapterSupport.invalidResponse
            }
            let type = field.type ?? (field.properties == nil ? "object" : "object")
            let disabled = field.enabled == false || field.index == false
            let sortableTypes: Set<String> = [
                "binary", "flattened", "geo_point", "geo_shape", "nested", "object", "text",
            ]
            descriptors.append(
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath(path),
                    displayName: path.joined(separator: "."),
                    typeName:
                        runtime
                        ? "runtime:" + type
                        : derived ? "derived:" + type : type,
                    isNullable: true,
                    isSortable: !insideNested && !disabled && !sortableTypes.contains(type)
                        && field.docValues != false,
                    isFilterable: !insideNested && !disabled))
            guard descriptors.count <= DatabaseAdapterBounds.maximumPageFields else {
                throw .limitExceeded(
                    limit: .pageFields,
                    actual: descriptors.count,
                    maximum: DatabaseAdapterBounds.maximumPageFields)
            }
            try appendFields(
                field.properties ?? [:],
                prefix: path,
                descriptors: &descriptors,
                runtime: runtime,
                derived: derived,
                insideNested: insideNested || type == "nested")
            try appendFields(
                field.fields ?? [:],
                prefix: path,
                descriptors: &descriptors,
                runtime: runtime,
                derived: derived,
                insideNested: insideNested || type == "nested")
        }
    }

    private static func discoveryRecord(
        kind: DatabaseObjectKind,
        name: String,
        fields: [DatabaseObjectField]
    ) -> DatabaseRecord {
        DatabaseRecord(
            identity: DatabaseRecordIdentity(
                kind: .key,
                components: [
                    DatabaseIdentityComponent(name: "name", value: .string(name)),
                    DatabaseIdentityComponent(name: "kind", value: .string(kind.rawValue)),
                ]),
            fields: [
                DatabaseObjectField(name: "kind", value: .string(kind.rawValue)),
                DatabaseObjectField(name: "name", value: .string(name)),
                DatabaseObjectField(name: "metadata", value: .object(fields)),
            ])
    }

    private static func digest(
        source: DatabaseAdapterPageRequest,
        language: DatabaseQueryLanguage?,
        command: String,
        parameters: [DatabaseQueryParameter],
        queryBody: DatabaseValue?
    ) throws(DatabaseAdapterFailure) -> String {
        let value = OpenSearchDatabaseDigestValue(
            target: source.target,
            pageSize: source.pageSize,
            projection: source.projection,
            filter: source.filter,
            sorts: source.sorts,
            consistency: source.consistency,
            language: language,
            command: command,
            parameters: parameters,
            body: queryBody)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
    }

    private static func encode(
        _ fields: [String: OpenSearchDatabaseJSONValue]
    ) throws(DatabaseAdapterFailure) -> Data {
        do {
            return try OpenSearchDatabaseJSONCodec.encode(.object(fields))
        } catch {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
    }

    private static func fieldName(
        _ path: DatabaseFieldPath
    ) throws(DatabaseAdapterFailure) -> String {
        guard !path.segments.isEmpty, path.segments.count <= 32,
            path.segments.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 4_096 && !$0.contains("\0")
                    && !$0.contains(".") && !$0.contains("*")
                    && !$0.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                    })
            })
        else {
            throw OpenSearchDatabaseAdapterSupport.invalidRequest
        }
        return path.segments.joined(separator: ".")
    }

    private static func escapedWildcard(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }
}

private struct OpenSearchDatabaseDigestValue: Encodable {
    let target: DatabaseTargetIdentifier
    let pageSize: DatabasePageSize
    let projection: DatabaseProjection?
    let filter: DatabaseFilter?
    let sorts: [DatabaseSort]
    let consistency: DatabaseConsistencyPreference
    let language: DatabaseQueryLanguage?
    let command: String
    let parameters: [DatabaseQueryParameter]
    let body: DatabaseValue?
}
