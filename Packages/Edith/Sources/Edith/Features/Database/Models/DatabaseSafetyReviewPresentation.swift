import EdithDatabase
import Foundation

enum DatabaseSafetyReviewPhase: Equatable {
    case ready
    case executing
    case cancelling
    case reconciling
    case outcomeUnknown(String)
    case failed(String)
    case accepted(String)
    case succeeded(String)

    var locksPreviewRefresh: Bool {
        switch self {
        case .executing, .cancelling, .reconciling, .outcomeUnknown, .accepted, .succeeded:
            true
        case .ready, .failed:
            false
        }
    }

    var allowsOperationCancellation: Bool {
        switch self {
        case .executing, .reconciling, .outcomeUnknown, .accepted:
            true
        case .ready, .cancelling, .failed, .succeeded:
            false
        }
    }

    var allowsReconciliation: Bool {
        switch self {
        case .outcomeUnknown, .accepted:
            true
        case .ready, .executing, .cancelling, .reconciling, .failed, .succeeded:
            false
        }
    }

    var preservesUnresolvedOperation: Bool {
        switch self {
        case .executing, .cancelling, .reconciling, .outcomeUnknown, .accepted:
            true
        case .ready, .failed, .succeeded:
            false
        }
    }

    var blocksInteractiveDismissal: Bool {
        switch self {
        case .executing, .cancelling, .reconciling:
            true
        case .ready, .outcomeUnknown, .failed, .accepted, .succeeded:
            false
        }
    }

    var message: String? {
        switch self {
        case let .outcomeUnknown(message), let .failed(message), let .accepted(message),
            let .succeeded(message):
            message
        case .ready, .executing, .cancelling, .reconciling:
            nil
        }
    }

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

enum DatabaseSafetyConfirmationState: Equatable {
    case empty
    case mismatch
    case ready
    case expired
    case executing
    case outcomeUnknown
    case failed
    case completed
}

enum DatabaseSafetyRiskLevel: Equatable {
    case guarded
    case high
    case critical

    var title: String {
        switch self {
        case .guarded: "Guarded change"
        case .high: "High-risk change"
        case .critical: "Critical change"
        }
    }

    var symbol: String {
        switch self {
        case .guarded: "lock.shield.fill"
        case .high: "exclamationmark.shield.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

struct DatabaseSafetyPreviewIdentity: Equatable {
    let token: DatabaseConfirmationToken
    let issuedAt: Date
    let expiresAt: Date

    init(preview: DatabaseDestructivePreview) {
        token = preview.token
        issuedAt = preview.issuedAt
        expiresAt = preview.expiresAt
    }
}

struct DatabaseSafetyReviewInteractionState: Equatable {
    private(set) var previewIdentity: DatabaseSafetyPreviewIdentity
    var confirmationInput = ""
    private(set) var refreshRequestID: UUID?
    private(set) var submittedPreviewIdentity: DatabaseSafetyPreviewIdentity?

    var refreshLocked: Bool { refreshRequestID != nil }
    var submissionLocked: Bool { submittedPreviewIdentity != nil }

    init(preview: DatabaseDestructivePreview) {
        previewIdentity = DatabaseSafetyPreviewIdentity(preview: preview)
    }

    mutating func replacePreview(_ preview: DatabaseDestructivePreview) -> Bool {
        let replacement = DatabaseSafetyPreviewIdentity(preview: preview)
        guard replacement != previewIdentity else { return false }
        previewIdentity = replacement
        confirmationInput = ""
        return true
    }

    mutating func beginRefresh() -> UUID? {
        guard refreshRequestID == nil else { return nil }
        let requestID = UUID()
        refreshRequestID = requestID
        return requestID
    }

    mutating func finishRefresh(_ requestID: UUID) {
        guard refreshRequestID == requestID else { return }
        refreshRequestID = nil
    }

    mutating func beginSubmission() -> Bool {
        guard submittedPreviewIdentity == nil else { return false }
        submittedPreviewIdentity = previewIdentity
        return true
    }

    mutating func finishSubmission() {
        submittedPreviewIdentity = nil
    }
}

struct DatabaseSafetyReviewLayout: Equatable {
    static let minimumSheetWidth = 320.0
    static let minimumSheetHeight = 320.0

    let usesWideHeader: Bool
    let usesPairedCards: Bool
    let usesInlineFooterActions: Bool

    init(width: Double, zoom: Double) {
        usesWideHeader = width >= 640 * zoom
        usesPairedCards = width >= 760 * zoom
        usesInlineFooterActions = width >= 560 * zoom
    }
}

struct DatabaseSafetyReviewFact: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    let symbol: String
}

struct DatabaseSafetyReviewWarning: Identifiable, Equatable {
    let id: String
    let message: String
    let severity: DatabaseWarningSeverity

    var severityTitle: String {
        switch severity {
        case .information: "Information"
        case .caution: "Caution"
        case .high: "High severity"
        }
    }

    var symbol: String {
        switch severity {
        case .information: "info.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .high: "exclamationmark.octagon.fill"
        }
    }
}

struct DatabaseSafetyReviewPresentation: Equatable {
    static let maximumRenderedTextCharacters = 4_096

    let actionTitle: String
    let actionButtonTitle: String
    let risk: DatabaseSafetyRiskLevel
    let connectionFacts: [DatabaseSafetyReviewFact]
    let selectionTitle: String
    let selectionDetail: String
    let impactTitle: String
    let impactDetail: String
    let behaviorFacts: [DatabaseSafetyReviewFact]
    let requestTitle: String
    let requestCommand: String
    let requestParameters: String?
    let requestBody: String?
    let warnings: [DatabaseSafetyReviewWarning]
    let confirmationInstruction: String
    let confirmationText: String
    let previewIdentity: DatabaseSafetyPreviewIdentity
    let expiresAt: Date

    init(preview: DatabaseDestructivePreview) {
        let effect = preview.effect
        let objectPath = effect.target.object?.path ?? []
        let environment = effect.connection.environment

        actionTitle = Self.actionTitle(effect.action)
        actionButtonTitle = Self.actionButtonTitle(effect.action, scope: effect.scope)
        risk = Self.riskLevel(effect)
        var renderedConnectionFacts = [
            DatabaseSafetyReviewFact(
                id: "connection", label: "Connection",
                value: Self.identifier(effect.connection.displayName),
                symbol: "externaldrive.connected.to.line.below"),
            DatabaseSafetyReviewFact(
                id: "environment", label: "Environment",
                value: Self.environmentDescription(environment),
                symbol: environment.kind == .production
                    ? "exclamationmark.triangle.fill" : "leaf.fill"),
            DatabaseSafetyReviewFact(
                id: "context", label: effect.context.kind.displayName,
                value: Self.identifier(effect.context.value),
                symbol: "cylinder.split.1x2"),
        ]
        if let catalog = effect.context.catalog {
            renderedConnectionFacts.append(
                DatabaseSafetyReviewFact(
                    id: "catalog", label: "Catalog", value: Self.identifier(catalog),
                    symbol: "books.vertical.fill"))
        }
        if let schema = effect.context.schema {
            renderedConnectionFacts.append(
                DatabaseSafetyReviewFact(
                    id: "schema", label: "Schema", value: Self.identifier(schema),
                    symbol: "square.3.layers.3d"))
        }
        renderedConnectionFacts.append(
            DatabaseSafetyReviewFact(
                id: "target", label: "Target object",
                value: objectPath.isEmpty
                    ? "Connection"
                    : Self.targetDescription(
                        object: effect.target.object,
                        path: objectPath),
                symbol: "scope"))
        connectionFacts = renderedConnectionFacts
        let selection = Self.selection(effect)
        selectionTitle = selection.title
        selectionDetail = selection.detail
        impactTitle = Self.impactTitle(effect.impact.count)
        impactDetail = Self.displayText(effect.impact.description)
        behaviorFacts = [
            DatabaseSafetyReviewFact(
                id: "transaction", label: "Transaction",
                value: Self.transactionTitle(effect.transactionBehavior),
                symbol: "arrow.triangle.2.circlepath"),
            DatabaseSafetyReviewFact(
                id: "rollback", label: "Rollback",
                value: Self.rollbackTitle(effect.rollbackAvailability),
                symbol: effect.rollbackAvailability == .available
                    ? "arrow.uturn.backward.circle.fill" : "nosign"),
            DatabaseSafetyReviewFact(
                id: "execution", label: "Execution",
                value: Self.executionTitle(effect.executionMode),
                symbol: effect.executionMode == .synchronous
                    ? "bolt.fill" : "clock.arrow.circlepath"),
        ]
        requestTitle =
            "\(preview.request.product.displayName) \(Self.payloadKindTitle(preview.request.kind))"
        requestCommand = Self.codeText(preview.request.command)
        requestParameters = Self.parameters(preview.request.parameters)
        requestBody = preview.request.body.map { Self.bounded(Self.value($0)) }
        var renderedWarnings = preview.warnings.enumerated().map { index, warning in
            DatabaseSafetyReviewWarning(
                id: "\(index)-\(warning.code)",
                message: Self.displayText(warning.message),
                severity: warning.severity)
        }
        if environment.kind == .production {
            renderedWarnings.insert(
                DatabaseSafetyReviewWarning(
                    id: "canonical-production",
                    message: "This operation targets a production connection.",
                    severity: .high),
                at: 0)
        }
        warnings = renderedWarnings
        confirmationInstruction = Self.confirmationInstruction(
            preview.requiredConfirmation.strength)
        confirmationText = preview.requiredConfirmation.text
        previewIdentity = DatabaseSafetyPreviewIdentity(preview: preview)
        expiresAt = preview.expiresAt
    }

    func confirmationState(
        input: String,
        now: Date,
        phase: DatabaseSafetyReviewPhase
    ) -> DatabaseSafetyConfirmationState {
        if phase == .executing || phase == .cancelling || phase == .reconciling {
            return .executing
        }
        if case .failed = phase { return .failed }
        if case .outcomeUnknown = phase { return .outcomeUnknown }
        if case .accepted = phase { return .completed }
        if case .succeeded = phase { return .completed }
        if now >= expiresAt { return .expired }
        if input.isEmpty { return .empty }
        return input == confirmationText ? .ready : .mismatch
    }

    func canConfirm(
        input: String,
        now: Date,
        phase: DatabaseSafetyReviewPhase
    ) -> Bool {
        confirmationState(input: input, now: now, phase: phase) == .ready
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, Int(ceil(expiresAt.timeIntervalSince(now))))
    }

    private static func riskLevel(_ effect: DatabaseDestructiveEffect)
        -> DatabaseSafetyRiskLevel
    {
        let criticalActions: Set<DatabaseDestructiveAction> = [
            .truncate, .dropObject, .schemaChange, .permissionChange, .terminateSession,
            .maintenance, .reindex, .asynchronousMutation,
        ]
        if effect.scope == .entireObject
            || effect.transactionBehavior != .transactional
            || effect.rollbackAvailability != .available
            || effect.executionMode == .asynchronous
            || criticalActions.contains(effect.action)
        {
            return .critical
        }
        if effect.connection.environment.kind == .production
            || effect.connection.environment.protection == .confirmationRequired
            || effect.action == .updateMany
            || effect.action == .deleteMany
        {
            return .high
        }
        return .guarded
    }

    private static func actionTitle(_ action: DatabaseDestructiveAction) -> String {
        switch action {
        case .insert: "Review insertion"
        case .update: "Review record update"
        case .updateMany: "Review bulk update"
        case .delete: "Review record deletion"
        case .deleteMany: "Review bulk deletion"
        case .truncate: "Review truncation"
        case .dropObject: "Review object removal"
        case .schemaChange: "Review schema change"
        case .permissionChange: "Review permission change"
        case .terminateSession: "Review session termination"
        case .maintenance: "Review maintenance"
        case .reindex: "Review reindexing"
        case .asynchronousMutation: "Review asynchronous mutation"
        }
    }

    private static func actionButtonTitle(
        _ action: DatabaseDestructiveAction,
        scope: DatabaseMutationScope
    ) -> String {
        switch action {
        case .insert: "Insert record"
        case .update: "Update record"
        case .updateMany: scope == .entireObject ? "Update entire object" : "Update records"
        case .delete: "Delete record"
        case .deleteMany: scope == .entireObject ? "Delete all records" : "Delete records"
        case .truncate: "Truncate object"
        case .dropObject: "Drop object"
        case .schemaChange: "Apply schema change"
        case .permissionChange: "Apply permission change"
        case .terminateSession: "Terminate session"
        case .maintenance: "Run maintenance"
        case .reindex: "Start reindex"
        case .asynchronousMutation: "Start mutation"
        }
    }

    private static func environmentDescription(
        _ environment: DatabaseEnvironmentMetadata
    ) -> String {
        let kind = environmentKindTitle(environment.kind)
        let label = environment.label.isEmpty ? kind : environment.label
        let identity =
            label.caseInsensitiveCompare(kind) == .orderedSame
            ? kind : "\(kind) (\(identifier(label)))"
        return "\(identity) · \(environmentProtectionTitle(environment.protection))"
    }

    private static func environmentKindTitle(_ kind: DatabaseEnvironmentKind) -> String {
        switch kind {
        case .local: "Local"
        case .development: "Development"
        case .testing: "Testing"
        case .staging: "Staging"
        case .production: "Production"
        case .other: "Other"
        }
    }

    private static func environmentProtectionTitle(
        _ protection: DatabaseEnvironmentProtection
    ) -> String {
        switch protection {
        case .standard: "standard controls"
        case .confirmationRequired: "confirmation required"
        case .readOnly: "read only"
        }
    }

    private static func selection(_ effect: DatabaseDestructiveEffect) -> (
        title: String, detail: String
    ) {
        switch effect.scope {
        case .singleRecord:
            return (
                "One record",
                effect.target.record.map(record) ?? "The target record identity is unavailable."
            )
        case .selectedRecords:
            let count = effect.selectedRecords.count
            return (
                "\(count) selected \(count == 1 ? "record" : "records")",
                selectedRecordDetail(effect.selectedRecords)
            )
        case .predicate:
            return (
                "Predicate",
                effect.predicate.map { bounded(filter($0)) }
                    ?? "The predicate is unavailable. Do not continue."
            )
        case .entireObject:
            return (
                "Entire object",
                "No predicate limits this operation. Every matching record in the target is in scope."
            )
        }
    }

    private static func impactTitle(_ count: DatabaseCountMetadata) -> String {
        let accuracy: String
        switch count.accuracy {
        case .unknown: accuracy = "Unknown impact"
        case .exact: accuracy = "Exact impact"
        case .estimated: accuracy = "Estimated impact"
        case .lowerBound: accuracy = "Minimum impact"
        case .upperBound: accuracy = "Maximum impact"
        }
        guard let value = count.value else { return accuracy }
        return "\(accuracy): \(value.formatted())"
    }

    private static func transactionTitle(_ behavior: DatabaseTransactionBehavior) -> String {
        switch behavior {
        case .transactional: "Transactional"
        case .nontransactional: "Not transactional"
        case .asynchronous: "Asynchronous transaction"
        case .productDependent: "Product dependent"
        }
    }

    private static func rollbackTitle(_ availability: DatabaseRollbackAvailability) -> String {
        switch availability {
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .conditional: "Conditional"
        }
    }

    private static func executionTitle(_ mode: DatabaseExecutionMode) -> String {
        switch mode {
        case .synchronous: "Synchronous"
        case .asynchronous: "Asynchronous"
        }
    }

    private static func payloadKindTitle(_ kind: DatabaseMutationPayloadKind) -> String {
        switch kind {
        case .sql: "SQL"
        case .keyspace: "keyspace command"
        case .document: "document request"
        case .search: "search request"
        case .analytical: "analytical query"
        case .administrative: "administrative request"
        }
    }

    private static func parameters(
        _ parameters: [DatabaseMutationParameterPreview]
    ) -> String? {
        guard !parameters.isEmpty else { return nil }
        return bounded(
            parameters.map { "\(identifier($0.name)): \(valueKindTitle($0.valueKind))" }
                .joined(separator: " · "))
    }

    private static func targetDescription(
        object: DatabaseObjectIdentifier?,
        path: [String]
    ) -> String {
        guard let object else { return "Connection" }
        let kind = objectKindTitle(object.kind)
        let renderedPath = path.map(identifier).joined(separator: " / ")
        let native =
            object.nativeIdentifier.map {
                " · native identity \(identifier($0))"
            } ?? ""
        return "\(kind): \(renderedPath)\(native)"
    }

    private static func objectKindTitle(_ kind: DatabaseObjectKind) -> String {
        switch kind {
        case .server: "Server"
        case .cluster: "Cluster"
        case .node: "Node"
        case .catalog: "Catalog"
        case .database: "Database"
        case .schema: "Schema"
        case .table: "Table"
        case .view: "View"
        case .materializedView: "Materialized view"
        case .column: "Column"
        case .index: "Index"
        case .constraint: "Constraint"
        case .sequence: "Sequence"
        case .routine: "Routine"
        case .type: "Type"
        case .role: "Role"
        case .keyspace: "Keyspace"
        case .key: "Key"
        case .collection: "Collection"
        case .alias: "Alias"
        case .dataStream: "Data stream"
        case .template: "Template"
        case .pipeline: "Pipeline"
        case .snapshot: "Snapshot"
        case .dictionary: "Dictionary"
        case .partition: "Partition"
        case .part: "Part"
        case .other: "Object"
        }
    }

    private static func valueKindTitle(_ kind: DatabaseValuePreviewKind) -> String {
        switch kind {
        case .missing: "missing"
        case .null: "null"
        case .boolean: "boolean"
        case .signedInteger: "signed integer"
        case .unsignedInteger: "unsigned integer"
        case .decimal: "decimal"
        case .floatingPoint: "floating point"
        case .string: "string"
        case .binary: "binary"
        case .date: "date"
        case .time: "time"
        case .timestamp: "timestamp"
        case .uuid: "UUID"
        case .array: "array"
        case .object: "object"
        case .productSpecific: "product-specific value"
        }
    }

    private static func confirmationInstruction(
        _ strength: DatabaseConfirmationStrength
    ) -> String {
        switch strength {
        case .explicit:
            "Type the exact confirmation word to authorize this operation."
        case .target:
            "Type the exact target identity to authorize this operation."
        case .connectionAndTarget:
            "Type the exact connection and target identity to authorize this operation."
        }
    }

    private static func filter(_ node: DatabaseFilter) -> String {
        switch node {
        case let .predicate(predicate):
            let field = predicate.field.segments.map(identifier).joined(separator: ".")
            let operation = filterOperatorTitle(predicate.operation)
            let values = predicate.values.map { value($0) }.joined(separator: ", ")
            let suffix = values.isEmpty ? "" : " \(values)"
            return
                "\(field) \(operation)\(suffix) [case sensitivity: \(caseSensitivityTitle(predicate.caseSensitivity))]"
        case let .all(children):
            return children.map { "(\(Self.filter($0)))" }.joined(separator: " AND ")
        case let .any(children):
            return children.map { "(\(Self.filter($0)))" }.joined(separator: " OR ")
        case let .not(child):
            return "NOT (\(Self.filter(child)))"
        }
    }

    private static func filterOperatorTitle(_ operation: DatabaseFilterOperator) -> String {
        switch operation {
        case .equal: "="
        case .notEqual: "≠"
        case .greaterThan: ">"
        case .greaterThanOrEqual: "≥"
        case .lessThan: "<"
        case .lessThanOrEqual: "≤"
        case .contains: "contains"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .in: "in"
        case .notIn: "not in"
        case .between: "between"
        case .isNull: "is null"
        case .isNotNull: "is not null"
        case .isMissing: "is missing"
        case .isNotMissing: "is not missing"
        case .regularExpression: "matches regex"
        case .fullText: "matches full text"
        }
    }

    private static func caseSensitivityTitle(
        _ sensitivity: DatabaseFilterCaseSensitivity
    ) -> String {
        switch sensitivity {
        case .productDefault: "product default"
        case .sensitive: "sensitive"
        case .insensitive: "insensitive"
        }
    }

    private static func record(_ record: DatabaseRecordIdentity) -> String {
        let components = record.components.prefix(16).map {
            "\(identifier($0.name))=\(value($0.value))"
        }
        let remainder =
            record.components.count > components.count
            ? ", +\(record.components.count - components.count) more" : ""
        return bounded(components.joined(separator: ", ") + remainder)
    }

    private static func selectedRecordDetail(_ records: [DatabaseRecordIdentity]) -> String {
        var rendered: [String] = []
        var characterCount = 0
        for identity in records.prefix(20) {
            let next = record(identity)
            let separatorCount = rendered.isEmpty ? 0 : 3
            guard characterCount + separatorCount + next.count <= 3_800 else { break }
            rendered.append(next)
            characterCount += separatorCount + next.count
        }
        let remainder = records.count - rendered.count
        if remainder > 0 {
            rendered.append(
                "+\(remainder) additional bound \(remainder == 1 ? "identity" : "identities")"
            )
        }
        return bounded(rendered.joined(separator: " · "))
    }

    private static func value(_ value: DatabaseValue, depth: Int = 0) -> String {
        if depth >= 3 { return "…" }
        switch value {
        case .missing: return "<missing>"
        case .null: return "null"
        case let .boolean(value): return value ? "true" : "false"
        case let .signedInteger(value): return String(value)
        case let .unsignedInteger(value): return String(value)
        case let .decimal(value): return value.rawValue
        case let .floatingPoint(value): return String(value)
        case let .string(value): return identifier(bounded(displayText(value), limit: 512))
        case let .binary(value):
            return "<\(value.byteCount) bytes\(value.isComplete ? "" : ", preview")>"
        case let .date(value): return value.text
        case let .time(value): return value.text
        case let .timestamp(value): return value.text
        case let .uuid(value): return value.uuidString.lowercased()
        case let .array(values):
            return
                "[\(values.prefix(4).map { self.value($0, depth: depth + 1) }.joined(separator: ", "))\(values.count > 4 ? ", …" : "")]"
        case let .object(fields):
            return
                "{\(fields.prefix(4).map { "\(identifier($0.name)): \(self.value($0.value, depth: depth + 1))" }.joined(separator: ", "))\(fields.count > 4 ? ", …" : "") }"
        case let .productSpecific(value):
            return value.textRepresentation.map { bounded(displayText($0), limit: 512) }
                ?? "<\(displayText(value.typeName, limit: 512))>"
        }
    }

    static func displayText(_ value: String, limit: Int = maximumRenderedTextCharacters) -> String {
        bounded(neutralized(value, preservesCodeLayout: false), limit: limit)
    }

    private static func codeText(_ value: String) -> String {
        bounded(neutralized(value, preservesCodeLayout: true))
    }

    private static func identifier(_ value: String) -> String {
        var rendered = "\""
        rendered.reserveCapacity(value.count + 2)
        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            if codePoint == 0x22 {
                rendered += "\\\""
            } else if codePoint == 0x5C {
                rendered += "\\\\"
            } else if codePoint == 0x09 {
                rendered += "\\t"
            } else if codePoint == 0x0A {
                rendered += "\\n"
            } else if codePoint == 0x0D {
                rendered += "\\r"
            } else if shouldEscape(scalar) {
                rendered += String(format: "\\u{%04X}", codePoint)
            } else {
                rendered.unicodeScalars.append(scalar)
            }
        }
        rendered += "\""
        return bounded(rendered)
    }

    private static func neutralized(_ value: String, preservesCodeLayout: Bool) -> String {
        var rendered = ""
        rendered.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            if preservesCodeLayout && (codePoint == 0x09 || codePoint == 0x0A) {
                rendered.unicodeScalars.append(scalar)
            } else if codePoint == 0x09 {
                rendered += "\\t"
            } else if codePoint == 0x0A {
                rendered += "\\n"
            } else if codePoint == 0x0D {
                rendered += "\\r"
            } else if shouldEscape(scalar) {
                rendered += String(format: "\\u{%04X}", codePoint)
            } else {
                rendered.unicodeScalars.append(scalar)
            }
        }
        return rendered
    }

    private static func shouldEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            true
        default:
            false
        }
    }

    private static func bounded(
        _ value: String,
        limit: Int = maximumRenderedTextCharacters
    ) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 1))) + "…"
    }
}
