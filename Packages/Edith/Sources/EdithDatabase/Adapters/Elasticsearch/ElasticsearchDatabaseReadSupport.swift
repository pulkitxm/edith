import CryptoKit
import Foundation

struct ElasticsearchDatabaseSearchPlan: Sendable {
    let target: String
    let body: Data
    let requestDigest: String
    let continuation: ElasticsearchDatabaseContinuationPayload?
    let aggregationOnly: Bool
}

struct ElasticsearchDatabaseContinuationPayload: Codable, Hashable, Sendable {
    static let version = 1

    let schemaVersion: Int
    let sessionID: UUID
    let connectionID: DatabaseConnectionID
    let target: DatabaseTargetIdentifier
    let requestDigest: String
    let pointInTimeID: String
    let sort: [ElasticsearchDatabaseJSONValue]
    let expiresAt: Date

    init(
        sessionID: DatabaseAdapterSessionID,
        connectionID: DatabaseConnectionID,
        target: DatabaseTargetIdentifier,
        requestDigest: String,
        pointInTimeID: String,
        sort: [ElasticsearchDatabaseJSONValue],
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

enum ElasticsearchDatabaseReadCompiler {
    private static let continuationLifetime: TimeInterval = 60
    private static let maximumQueryNodes = 20_000
    private static let maximumQueryDepth = 32
    private static let maximumArrayElements = 10_000
    private static let maximumQueryFields = 512
    private static let maximumAggregations = 16
    private static let maximumAggregationDepth = 4
    private static let maximumHighlightFields = 16
    private static let forbiddenKeys: Set<String> = [
        "_scripts", "collapse", "docvalue_fields", "fields", "from", "knn", "pit",
        "post_filter", "profile", "rank", "rescore", "retriever", "runtime_mappings",
        "script", "script_fields", "search_after", "size", "stored_fields", "suggest",
    ]

    static func compileBrowse(
        _ request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        requestTimeoutMilliseconds: UInt64,
        now: Date = Date()
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseSearchPlan {
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
        return ElasticsearchDatabaseSearchPlan(
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
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseSearchPlan {
        guard request.language == .searchQueryDSL, request.parameters.isEmpty else {
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
        let aggregationOnly: Bool
        switch request.command {
        case "search":
            aggregationOnly = false
        case "aggregate":
            aggregationOnly = true
        default:
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
        let target = try documentTarget(request.source.target)
        let supplied: [String: ElasticsearchDatabaseJSONValue]
        if let body = request.body {
            let value: ElasticsearchDatabaseJSONValue
            do {
                value = try ElasticsearchDatabaseJSONValue(databaseValue: body)
            } catch {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            guard case let .object(fields) = value else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
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
            throw ElasticsearchDatabaseAdapterSupport.invalidContinuation
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
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
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
        return ElasticsearchDatabaseSearchPlan(
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
        sort: [ElasticsearchDatabaseJSONValue],
        now: Date = Date()
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterContinuation {
        guard ElasticsearchDatabaseDriverSupport.validOpaqueIdentifier(pointInTimeID),
            !sort.isEmpty,
            sort.count <= DatabaseAdapterBounds.maximumSorts + 1,
            sort.allSatisfy({ $0.isBoundedScalar() })
        else {
            throw ElasticsearchDatabaseAdapterSupport.invalidResponse
        }
        let expiresAt = now.addingTimeInterval(continuationLifetime)
        let value = ElasticsearchDatabaseContinuationPayload(
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
            throw ElasticsearchDatabaseAdapterSupport.invalidResponse
        }
        return try DatabaseAdapterContinuation(
            mode: .pointInTime,
            payload: payload,
            expiresAt: expiresAt)
    }

    static func fieldDescriptors(
        _ response: ElasticsearchDatabaseMappingResponse
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
        response: ElasticsearchDatabaseResolveResponse,
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
                    code: "elasticsearch.discovery.truncated",
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
                        code: "elasticsearch.metadata.permission",
                        message: "Elasticsearch denied index metadata discovery.",
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
            ElasticsearchDatabaseDriverSupport.validTargetName(value)
        else {
            throw ElasticsearchDatabaseAdapterSupport.invalidTarget
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
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseContinuationPayload? {
        guard let continuation else { return nil }
        guard continuation.mode == .pointInTime,
            continuation.expiresAt.map({ $0 > now }) ?? false
        else {
            throw ElasticsearchDatabaseAdapterSupport.invalidContinuation
        }
        let value: ElasticsearchDatabaseContinuationPayload
        do {
            value = try JSONDecoder().decode(
                ElasticsearchDatabaseContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw ElasticsearchDatabaseAdapterSupport.invalidContinuation
        }
        guard value.schemaVersion == ElasticsearchDatabaseContinuationPayload.version,
            value.sessionID == sessionID.rawValue,
            value.connectionID == request.target.connectionID,
            value.target == request.target,
            value.requestDigest == digest,
            value.expiresAt > now,
            continuation.expiresAt == value.expiresAt,
            ElasticsearchDatabaseDriverSupport.validOpaqueIdentifier(value.pointInTimeID),
            !value.sort.isEmpty,
            value.sort.count <= DatabaseAdapterBounds.maximumSorts + 1,
            value.sort.allSatisfy({ $0.isBoundedScalar() })
        else {
            throw ElasticsearchDatabaseAdapterSupport.invalidContinuation
        }
        return value
    }

    private static func commonBody(
        _ request: DatabaseAdapterPageRequest,
        requestTimeoutMilliseconds: UInt64,
        continuation: ElasticsearchDatabaseContinuationPayload?
    ) throws(DatabaseAdapterFailure) -> [String: ElasticsearchDatabaseJSONValue] {
        guard request.consistency != .strong else {
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
        var body: [String: ElasticsearchDatabaseJSONValue] = [
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
        supplied: ElasticsearchDatabaseJSONValue?,
        filter: DatabaseFilter?
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseJSONValue {
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
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseJSONValue {
        guard depth <= 16 else { throw ElasticsearchDatabaseAdapterSupport.invalidRequest }
        switch filter {
        case let .predicate(predicate):
            return try query(predicate)
        case let .all(children):
            guard !children.isEmpty, children.count <= 64 else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            var clauses: [ElasticsearchDatabaseJSONValue] = []
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
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            var clauses: [ElasticsearchDatabaseJSONValue] = []
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
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseJSONValue {
        let field = try fieldName(predicate.field)
        var values: [ElasticsearchDatabaseJSONValue] = []
        values.reserveCapacity(predicate.values.count)
        do {
            for value in predicate.values {
                values.append(try ElasticsearchDatabaseJSONValue(databaseValue: value))
            }
        } catch {
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
        let insensitive = predicate.caseSensitivity == .insensitive
        let term: (ElasticsearchDatabaseJSONValue) -> ElasticsearchDatabaseJSONValue = { value in
            var options: [String: ElasticsearchDatabaseJSONValue] = ["value": value]
            if insensitive { options["case_insensitive"] = .boolean(true) }
            return .object(["term": .object([field: .object(options)])])
        }
        switch predicate.operation {
        case .equal:
            guard values.count == 1 else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            return term(values[0])
        case .notEqual:
            guard values.count == 1 else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            return .object(["bool": .object(["must_not": .array([term(values[0])])])])
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            guard values.count == 1 else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
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
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            let terms = ElasticsearchDatabaseJSONValue.object([
                "terms": .object([field: .array(values)])
            ])
            if predicate.operation == .notIn {
                return .object(["bool": .object(["must_not": .array([terms])])])
            }
            return terms
        case .between:
            guard values.count == 2 else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            return .object([
                "range": .object([field: .object(["gte": values[0], "lte": values[1]])])
            ])
        case .isMissing, .isNull:
            guard values.isEmpty else { throw ElasticsearchDatabaseAdapterSupport.invalidRequest }
            let exists = ElasticsearchDatabaseJSONValue.object([
                "exists": .object(["field": .string(field)])
            ])
            return .object(["bool": .object(["must_not": .array([exists])])])
        case .isNotMissing, .isNotNull:
            guard values.isEmpty else { throw ElasticsearchDatabaseAdapterSupport.invalidRequest }
            return .object(["exists": .object(["field": .string(field)])])
        case .fullText:
            guard values.count == 1, case let .string(value) = values[0] else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            return .object(["match": .object([field: .string(value)])])
        case .contains, .startsWith, .endsWith, .regularExpression:
            guard values.count == 1, case let .string(value) = values[0],
                value.utf8.count <= 256
            else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            let pattern =
                switch predicate.operation {
                case .contains: "*" + escapedWildcard(value) + "*"
                case .startsWith: escapedWildcard(value) + "*"
                case .endsWith: "*" + escapedWildcard(value)
                default: value
                }
            let clause = predicate.operation == .regularExpression ? "regexp" : "wildcard"
            var options: [String: ElasticsearchDatabaseJSONValue] = ["value": .string(pattern)]
            if insensitive { options["case_insensitive"] = .boolean(true) }
            if clause == "regexp" { options["max_determinized_states"] = .signedInteger(10_000) }
            return .object([clause: .object([field: .object(options)])])
        }
    }

    private static func sorts(
        _ sorts: [DatabaseSort]
    ) throws(DatabaseAdapterFailure) -> [ElasticsearchDatabaseJSONValue] {
        var values: [ElasticsearchDatabaseJSONValue] = []
        values.reserveCapacity(sorts.count + 1)
        for sort in sorts {
            let field = try fieldName(sort.field)
            guard field != "_id", field != "_shard_doc" else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            var options: [String: ElasticsearchDatabaseJSONValue] = [
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
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseJSONValue {
        guard !projection.fields.isEmpty else {
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
        var fields: [ElasticsearchDatabaseJSONValue] = []
        fields.reserveCapacity(projection.fields.count)
        for projected in projection.fields {
            guard projected.alias == nil else {
                throw ElasticsearchDatabaseAdapterSupport.invalidRequest
            }
            fields.append(.string(try fieldName(projected.path)))
        }
        return .object([
            projection.mode == .include ? "includes" : "excludes": .array(fields)
        ])
    }

    private static func validateQueryBody(
        _ body: [String: ElasticsearchDatabaseJSONValue],
        aggregationOnly: Bool
    ) throws(DatabaseAdapterFailure) {
        let allowed: Set<String> =
            aggregationOnly
            ? ["query", "aggs", "aggregations", "track_total_hits"]
            : ["query", "highlight", "track_total_hits"]
        guard Set(body.keys).isSubset(of: allowed),
            !(body["aggs"] != nil && body["aggregations"] != nil)
        else {
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
        if let query = body["query"] {
            var nodes = 0
            try validateTree(
                query,
                key: "query",
                depth: 0,
                nodes: &nodes)
        }
    }

    private static func validateTree(
        _ value: ElasticsearchDatabaseJSONValue,
        key: String?,
        depth: Int,
        nodes: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard depth <= maximumQueryDepth, nodes < maximumQueryNodes else {
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
        nodes += 1
        if let key {
            let normalized = key.lowercased()
            if forbiddenKeys.contains(normalized) || normalized.contains("script") {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        switch value {
        case let .array(values):
            guard values.count <= maximumArrayElements else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
            for child in values {
                try validateTree(child, key: nil, depth: depth + 1, nodes: &nodes)
            }
        case let .object(values):
            guard values.count <= maximumQueryFields else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
            for (name, child) in values {
                guard !name.isEmpty, name.utf8.count <= 4_096, !name.contains("\0") else {
                    throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
                }
                try validateTree(child, key: name, depth: depth + 1, nodes: &nodes)
            }
        case let .string(value):
            guard value.utf8.count <= 1_048_576, !value.contains("\0") else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
        case .floatingPoint(let value):
            guard value.isFinite else { throw ElasticsearchDatabaseAdapterSupport.unsafeRequest }
        case .null, .boolean, .signedInteger, .unsignedInteger:
            break
        }
    }

    private static func validateAggregations(
        _ value: ElasticsearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(aggregations) = value,
            !aggregations.isEmpty,
            aggregations.count <= maximumAggregations
        else {
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
        var count = 0
        try validateAggregationObject(aggregations, depth: 0, count: &count)
    }

    private static func validateAggregationObject(
        _ aggregations: [String: ElasticsearchDatabaseJSONValue],
        depth: Int,
        count: inout Int
    ) throws(DatabaseAdapterFailure) {
        guard depth <= maximumAggregationDepth else {
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
        for (name, aggregation) in aggregations {
            guard ElasticsearchDatabaseDriverSupport.validTargetName(name),
                case let .object(configuration) = aggregation
            else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
            count += 1
            guard count <= maximumAggregations else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
            if let nested = configuration["aggs"] ?? configuration["aggregations"] {
                guard case let .object(children) = nested else {
                    throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
                }
                try validateAggregationObject(children, depth: depth + 1, count: &count)
            }
            guard
                !configuration.keys.contains(where: {
                    $0.lowercased().contains("script")
                        || ["from", "scroll", "search_after", "pit"].contains($0.lowercased())
                })
            else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
            try validateAggregationSizes(configuration)
        }
    }

    private static func validateAggregationSizes(
        _ value: [String: ElasticsearchDatabaseJSONValue]
    ) throws(DatabaseAdapterFailure) {
        for child in value.values {
            guard case let .object(configuration) = child else { continue }
            for key in ["size", "shard_size"] {
                if let limit = configuration[key] {
                    let maximum: Int64 = key == "size" ? 100 : 1_000
                    guard case let .signedInteger(value) = limit, value >= 0, value <= maximum
                    else {
                        throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
                    }
                }
            }
        }
    }

    private static func validateHighlight(
        _ value: ElasticsearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        guard case let .object(configuration) = value,
            Set(configuration.keys).isSubset(of: ["fields", "number_of_fragments", "fragment_size"]
            ),
            case let .object(fields)? = configuration["fields"],
            !fields.isEmpty,
            fields.count <= maximumHighlightFields
        else {
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
        for (name, value) in fields {
            guard
                (try? fieldName(DatabaseFieldPath(name.split(separator: ".").map(String.init))))
                    != nil,
                case let .object(options) = value,
                Set(options.keys).isSubset(of: ["number_of_fragments", "fragment_size"])
            else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
            try validateHighlightLimits(options)
        }
        try validateHighlightLimits(configuration)
    }

    private static func validateHighlightLimits(
        _ configuration: [String: ElasticsearchDatabaseJSONValue]
    ) throws(DatabaseAdapterFailure) {
        if let fragments = configuration["number_of_fragments"] {
            guard case let .signedInteger(value) = fragments, (0...5).contains(value) else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
        }
        if let size = configuration["fragment_size"] {
            guard case let .signedInteger(value) = size, (1...1_024).contains(value) else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
        }
    }

    private static func validateTrackTotalHits(
        _ value: ElasticsearchDatabaseJSONValue
    ) throws(DatabaseAdapterFailure) {
        switch value {
        case .boolean:
            return
        case let .signedInteger(limit):
            guard (0...100_000).contains(limit) else {
                throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
            }
        default:
            throw ElasticsearchDatabaseAdapterSupport.unsafeRequest
        }
    }

    private static func appendFields(
        _ fields: [String: ElasticsearchDatabaseMappingResponse.Field],
        prefix: [String],
        descriptors: inout [DatabaseFieldDescriptor],
        runtime: Bool = false
    ) throws(DatabaseAdapterFailure) {
        for name in fields.keys.sorted() {
            guard let field = fields[name],
                !name.isEmpty,
                name.utf8.count <= 4_096,
                !name.contains("\0")
            else {
                throw ElasticsearchDatabaseAdapterSupport.invalidResponse
            }
            let path = prefix + [name]
            guard path.count <= 32 else {
                throw ElasticsearchDatabaseAdapterSupport.invalidResponse
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
                    typeName: runtime ? "runtime:" + type : type,
                    isNullable: true,
                    isSortable: !disabled && !sortableTypes.contains(type)
                        && field.docValues != false,
                    isFilterable: !disabled))
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
                runtime: runtime)
            try appendFields(
                field.fields ?? [:],
                prefix: path,
                descriptors: &descriptors,
                runtime: runtime)
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
        let value = ElasticsearchDatabaseDigestValue(
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
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
    }

    private static func encode(
        _ fields: [String: ElasticsearchDatabaseJSONValue]
    ) throws(DatabaseAdapterFailure) -> Data {
        do {
            return try ElasticsearchDatabaseJSONCodec.encode(.object(fields))
        } catch {
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
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
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
        return path.segments.joined(separator: ".")
    }

    private static func escapedWildcard(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }
}

private struct ElasticsearchDatabaseDigestValue: Encodable {
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
