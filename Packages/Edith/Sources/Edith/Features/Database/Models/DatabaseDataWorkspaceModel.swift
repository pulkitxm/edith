import AppKit
import EdithDatabase
import Foundation
import Observation

enum DatabaseDataWorkspaceState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class DatabaseDataWorkspaceModel {
    var targetText = ""
    var filterField = ""
    var filterValue = ""
    var sortField = ""
    var sortDirection = DatabaseSortDirection.ascending
    private(set) var state = DatabaseDataWorkspaceState.idle
    private(set) var records: [DatabaseRecord] = []
    private(set) var fields: [DatabaseFieldDescriptor] = []
    private(set) var selectedRecordIndex: Int?
    private(set) var nextContinuation: DatabaseContinuationToken?
    private(set) var metadata: DatabasePageMetadata?

    private let sender: any DatabaseBrokerCommandSending
    private let announcement: @MainActor (String) -> Void
    private var activeTask: Task<Void, Never>?
    private var generation = UUID()
    private var activeConnectionID: DatabaseConnectionID?

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
        announcement: @escaping @MainActor (String) -> Void = DatabaseDataWorkspaceModel.announce
    ) {
        self.sender = sender
        self.announcement = announcement
    }

    var selectedRecord: DatabaseRecord? {
        guard let selectedRecordIndex, records.indices.contains(selectedRecordIndex) else {
            return nil
        }
        return records[selectedRecordIndex]
    }

    var hasNextPage: Bool {
        nextContinuation != nil
    }

    var isLoading: Bool {
        state == .loading
    }

    func prepare(for connection: DatabaseConnectionSummary?) {
        guard activeConnectionID != connection?.id else { return }
        cancel()
        activeConnectionID = connection?.id
        records = []
        fields = []
        selectedRecordIndex = nil
        nextContinuation = nil
        metadata = nil
        filterField = ""
        filterValue = ""
        sortField = ""
        sortDirection = .ascending
        state = .idle
        targetText = connection.map(Self.initialTargetText) ?? ""
    }

    func browse(_ connection: DatabaseConnectionSummary, appending: Bool = false) {
        guard !isLoading else { return }
        let continuation = appending ? nextContinuation : nil
        if appending, continuation == nil { return }
        let request: DatabaseBrowseRequest
        do {
            request = try browseRequest(connection, continuation: continuation)
        } catch {
            state = .failed(Self.message(for: error))
            announcement(Self.message(for: error))
            return
        }

        activeTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        state = .loading
        let sender = sender
        activeTask = Task { [weak self] in
            do {
                let response = try await sender.send(.browse(request))
                try Task.checkCancellation()
                self?.finish(
                    response,
                    connectionID: connection.id,
                    generation: requestGeneration,
                    appending: appending)
            } catch is CancellationError {
            } catch {
                self?.fail(error, generation: requestGeneration)
            }
        }
    }

    func refresh(_ connection: DatabaseConnectionSummary) {
        browse(connection)
    }

    func loadNextPage(_ connection: DatabaseConnectionSummary) {
        browse(connection, appending: true)
    }

    func selectRecord(at index: Int) {
        guard records.indices.contains(index) else { return }
        selectedRecordIndex = selectedRecordIndex == index ? nil : index
        announcement(selectedRecordIndex == nil ? "Closed row details." : "Opened row details.")
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        generation = UUID()
        if state == .loading {
            state = records.isEmpty ? .idle : .loaded
        }
    }

    func text(for value: DatabaseValue) -> String {
        Self.text(for: value)
    }

    func value(named name: String, in record: DatabaseRecord) -> DatabaseValue {
        record.fields.first(where: { $0.name == name })?.value ?? .missing
    }

    private func browseRequest(
        _ connection: DatabaseConnectionSummary,
        continuation: DatabaseContinuationToken?
    ) throws -> DatabaseBrowseRequest {
        let pageSize = try DatabasePageSize(200)
        let filter: DatabaseFilter?
        let normalizedFilterField = filterField.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilterValue = filterValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedFilterField.isEmpty || normalizedFilterValue.isEmpty {
            filter = nil
        } else {
            filter = .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath(normalizedFilterField),
                    operation: .contains,
                    values: [.string(normalizedFilterValue)],
                    caseSensitivity: .insensitive))
        }
        let normalizedSort = sortField.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorts =
            normalizedSort.isEmpty
            ? []
            : [
                DatabaseSort(
                    field: DatabaseFieldPath(normalizedSort),
                    direction: sortDirection)
            ]
        return DatabaseBrowseRequest(
            target: try target(connection),
            page: DatabasePageRequest(
                pageSize: pageSize,
                continuation: continuation,
                filter: filter,
                sorts: sorts))
    }

    private func target(
        _ connection: DatabaseConnectionSummary
    ) throws -> DatabaseTargetIdentifier {
        let entered = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = entered.split(separator: ".", omittingEmptySubsequences: true).map(
            String.init)
        let object: DatabaseObjectIdentifier
        switch connection.product {
        case .postgresql:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultSchema ?? "public",
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .table, path: path)
        case .sqlite:
            guard (1...2).contains(segments.count) else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter a table name, such as customers.")
            }
            object = DatabaseObjectIdentifier(kind: .table, path: segments)
        case .mysql, .mariaDB:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultDatabase,
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .table, path: path)
        case .redis, .valkey:
            guard segments.count <= 1 else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter one logical database number or leave it empty.")
            }
            let path =
                segments.isEmpty
                ? connection.logicalDatabase.map { [$0] } ?? []
                : segments
            object = DatabaseObjectIdentifier(kind: .keyspace, path: path)
        case .mongoDB:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultDatabase,
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .collection, path: path)
        case .elasticsearch, .openSearch:
            guard segments.count == 1 else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter one index name, such as products.")
            }
            object = DatabaseObjectIdentifier(kind: .index, path: segments)
        case .clickHouse:
            let path = try relationalPath(
                segments,
                defaultNamespace: connection.defaultDatabase,
                product: connection.product)
            object = DatabaseObjectIdentifier(kind: .table, path: path)
        }
        return DatabaseTargetIdentifier(connectionID: connection.id, object: object)
    }

    private func relationalPath(
        _ segments: [String],
        defaultNamespace: String?,
        product: DatabaseProduct
    ) throws -> [String] {
        if segments.count == 2 { return segments }
        if segments.count == 1, let defaultNamespace {
            return [defaultNamespace, segments[0]]
        }
        throw DatabaseDataWorkspaceInputError.invalidTarget(
            "Enter a namespace and object, such as public.customers, for \(product.displayName).")
    }

    private func finish(
        _ response: DatabaseBrokerCommandResponse,
        connectionID: DatabaseConnectionID,
        generation: UUID,
        appending: Bool
    ) {
        guard self.generation == generation, activeConnectionID == connectionID else { return }
        activeTask = nil
        guard case .browse(let result) = response else {
            state = .failed("The database returned an unexpected browse response.")
            return
        }
        guard result.status != .failed, let page = result.payload?.page else {
            state = .failed(Self.message(for: result.error))
            announcement(Self.message(for: result.error))
            return
        }
        if appending {
            records.append(contentsOf: page.records)
        } else {
            records = page.records
            selectedRecordIndex = nil
        }
        fields = page.fields
        nextContinuation = page.nextContinuation
        metadata = page.metadata
        state = .loaded
        announcement("Loaded \(page.records.count) database records.")
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        activeTask = nil
        let message = Self.message(for: error)
        state = .failed(message)
        announcement(message)
    }

    private static func initialTargetText(_ connection: DatabaseConnectionSummary) -> String {
        switch connection.product {
        case .redis, .valkey:
            connection.logicalDatabase ?? ""
        case .postgresql:
            connection.defaultSchema.map { "\($0)." } ?? "public."
        case .mysql, .mariaDB, .mongoDB, .clickHouse:
            connection.defaultDatabase.map { "\($0)." } ?? ""
        case .sqlite, .elasticsearch, .openSearch:
            ""
        }
    }

    private static func text(for value: DatabaseValue) -> String {
        switch value {
        case .missing: "missing"
        case .null: "null"
        case .boolean(let value): value ? "true" : "false"
        case .signedInteger(let value): value.formatted()
        case .unsignedInteger(let value): value.formatted()
        case .decimal(let value): value.rawValue
        case .floatingPoint(let value): value.formatted()
        case .string(let value): value
        case .binary(let value): "\(value.byteCount.formatted()) bytes"
        case .date(let value): value.text
        case .time(let value): value.text
        case .timestamp(let value): value.text
        case .uuid(let value): value.uuidString.lowercased()
        case .array(let values): "[\(values.count) values]"
        case .object(let fields): "{\(fields.count) fields}"
        case .productSpecific(let value): value.textRepresentation ?? value.typeName
        }
    }

    private static func message(for error: Error) -> String {
        if let inputError = error as? DatabaseDataWorkspaceInputError {
            switch inputError {
            case .invalidTarget(let message): return message
            }
        }
        if let client = error as? DatabaseBrokerCommandClientError {
            switch client {
            case .timedOut: return "The data request timed out."
            case .unavailable: return "The database broker is unavailable."
            case .unsafePeer: return "The database broker could not be verified."
            case .outcomeUnknown: return "The data request outcome could not be confirmed."
            case .invalidRequest: return "The database rejected this data request."
            }
        }
        return "The data could not be loaded."
    }

    private static func message(for error: DatabaseErrorEnvelope?) -> String {
        error?.message ?? "The data could not be loaded."
    }

    private static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}

private enum DatabaseDataWorkspaceInputError: Error {
    case invalidTarget(String)
}
