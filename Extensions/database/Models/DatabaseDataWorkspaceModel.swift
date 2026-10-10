import DatabaseCore
import Foundation
import Observation

@MainActor
@Observable
final class DatabaseDataWorkspaceModel {
    var targetText = ""
    var queryText = ""
    var searchQueryOperation = DatabaseSearchQueryOperation.search
    private(set) var filterClauses: [DatabaseWorkspaceFilterClause] = []
    private(set) var filterConjunction = DatabaseWorkspaceFilterConjunction.and
    private(set) var orderedSorts: [DatabaseWorkspaceSort] = []
    private(set) var state = DatabaseDataWorkspaceState.idle
    private(set) var resultMode = DatabaseDataResultMode.browse
    private(set) var recordsRevision = 0
    private(set) var recordsAppendedFrom: Int?
    private(set) var records: [DatabaseRecord] = [] {
        didSet {
            recordsRevision &+= 1
            recordsAppendedFrom = nil
        }
    }
    private(set) var fields: [DatabaseFieldDescriptor] = []
    private(set) var objectFields: [DatabaseFieldDescriptor] = []
    var selectedRecordIndex: Int?
    private(set) var nextContinuation: DatabaseContinuationToken?
    private(set) var metadata: DatabasePageMetadata?
    private(set) var pageSize = 100
    var editorMode: DatabaseRowEditorMode?
    var editorFields: [DatabaseRowFieldDraft] = []
    var documentText = ""
    var editorError: String?
    private(set) var selectedObject: DatabaseObjectIdentifier?
    var activeConnection: DatabaseConnectionSummary?
    var activeConnectionID: DatabaseConnectionID?
    var activeProduct: DatabaseProduct?

    private let sender: any DatabaseBrokerCommandSending
    private let announcement: @MainActor (String) -> Void
    private var activeTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastQueryRequest: DatabaseQueryRequest?
    private var browseQueryIsCurrent = false
    private var preparesBrowseQuery = false

    init(
        sender: any DatabaseBrokerCommandSending = DatabaseWorkerClient(),
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

    static let pageSizeOptions = [25, 50, 100]
    var hasNextPage: Bool { nextContinuation != nil }
    var isLoading: Bool { state == .loading }
    var activeFilterCount: Int { filterClauses.count(where: \.isEnabled) }
    var hasActiveFilters: Bool { activeFilterCount > 0 }
    var activeSortCount: Int { orderedSorts.count }
    var hasActiveSorts: Bool { !orderedSorts.isEmpty }

    var activeFilterSummary: String {
        let enabled = filterClauses.filter(\.isEnabled)
        guard !enabled.isEmpty else { return "No active filters" }
        if enabled.count == 1 { return enabled[0].summary }
        return "\(enabled.count) filters, match \(filterConjunction == .and ? "all" : "any")"
    }

    var activeSortSummary: String {
        orderedSorts.isEmpty
            ? "No active sorts" : orderedSorts.map(\.summary).joined(separator: ", ")
    }

    func defaultFilterOperator(for field: DatabaseFieldDescriptor) -> DatabaseFilterOperator {
        DatabaseFilterOperatorPolicy.defaultOperator(product: activeProduct, field: field)
    }

    @discardableResult
    func addFilterClause(
        field: String, operation: DatabaseFilterOperator? = nil, valueText: String = "",
        isEnabled: Bool = true, caseSensitivity: DatabaseFilterCaseSensitivity? = nil
    ) -> UUID {
        let normalizedField = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = fields.first { $0.path.segments.joined(separator: ".") == normalizedField }
        let resolvedOperation =
            operation ?? descriptor.map(defaultFilterOperator(for:)) ?? .contains
        let clause = DatabaseWorkspaceFilterClause(
            field: normalizedField, operation: resolvedOperation, valueText: valueText,
            isEnabled: isEnabled,
            caseSensitivity: caseSensitivity
                ?? DatabaseFilterOperatorPolicy.defaultCaseSensitivity(
                    product: activeProduct, field: descriptor, operation: resolvedOperation))
        filterClauses.append(clause)
        resetBrowsePaging()
        return clause.id
    }

    func updateFilterClause(_ clause: DatabaseWorkspaceFilterClause) {
        guard let index = filterClauses.firstIndex(where: { $0.id == clause.id }) else { return }
        filterClauses[index] = clause
        resetBrowsePaging()
    }

    func removeFilterClause(id: UUID) {
        guard let index = filterClauses.firstIndex(where: { $0.id == id }) else { return }
        filterClauses.remove(at: index)
        resetBrowsePaging()
    }

    func setFilterConjunction(_ conjunction: DatabaseWorkspaceFilterConjunction) {
        guard
            conjunction == .and
                || DatabaseFilterOperatorPolicy.supportsDisjunction(product: activeProduct),
            filterConjunction != conjunction
        else { return }
        filterConjunction = conjunction
        resetBrowsePaging()
    }

    func clearFilters() {
        filterClauses = []
        filterConjunction = .and
        resetBrowsePaging()
    }

    func cycleSort(field: String, additive: Bool) {
        let field = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty else { return }
        if let current = orderedSorts.first(where: { $0.field == field }) {
            if current.direction == .ascending {
                setSort(field: field, direction: .descending, additive: additive)
            } else if additive {
                removeSort(field: field)
            } else {
                clearSorts()
            }
        } else {
            setSort(field: field, direction: .ascending, additive: additive)
        }
    }

    func setSort(field: String, direction: DatabaseSortDirection, additive: Bool) {
        let field = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty else { return }
        let sort = DatabaseWorkspaceSort(field: field, direction: direction)
        var sorts = orderedSorts
        if additive {
            if let index = sorts.firstIndex(where: { $0.field == field }) {
                sorts[index] = sort
            } else {
                sorts.append(sort)
            }
        } else {
            sorts = [sort]
        }
        guard sorts != orderedSorts else { return }
        orderedSorts = sorts
        resetBrowsePaging()
    }

    func removeSort(field: String) {
        let field = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard orderedSorts.contains(where: { $0.field == field }) else { return }
        orderedSorts.removeAll { $0.field == field }
        resetBrowsePaging()
    }

    func moveSort(field: String, to destination: Int) {
        let field = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = orderedSorts.firstIndex(where: { $0.field == field }) else { return }
        let destination = min(max(destination, 0), orderedSorts.count - 1)
        guard source != destination else { return }
        let sort = orderedSorts.remove(at: source)
        orderedSorts.insert(sort, at: destination)
        resetBrowsePaging()
    }

    func clearSorts() {
        guard !orderedSorts.isEmpty else { return }
        orderedSorts = []
        resetBrowsePaging()
    }

    func prepare(for connection: DatabaseConnectionSummary?) {
        guard activeConnectionID != connection?.id else { return }
        cancel()
        activeConnection = connection
        activeConnectionID = connection?.id
        activeProduct = connection?.product
        resetResults()
        cancelEditor()
        objectFields = []
        selectedObject = nil
        filterClauses = []
        filterConjunction = .and
        orderedSorts = []
        queryText = ""
        searchQueryOperation = .search
        resultMode = .browse
        targetText = connection.map(Self.initialTargetText) ?? ""
    }

    func browse(_ connection: DatabaseConnectionSummary, appending: Bool = false) {
        guard !isLoading else { return }
        let continuation = appending ? nextContinuation : nil
        if appending, continuation == nil { return }
        if !appending { lastQueryRequest = nil }
        do {
            let request = try browseRequest(connection, continuation: continuation)
            execute(.browse(request), connection: connection, appending: appending, mode: .browse)
        } catch { fail(error, generation: generation) }
    }

    func refresh(_ connection: DatabaseConnectionSummary) { browse(connection) }

    func open(_ object: DatabaseObjectIdentifier, connection: DatabaseConnectionSummary) {
        prepareTarget(object, connection: connection, mode: .browse)
        browse(connection)
    }

    func prepareQuery(_ object: DatabaseObjectIdentifier, connection: DatabaseConnectionSummary) {
        if connection.product == .postgresql, selectedObject == object {
            if browseQueryIsCurrent, let query = metadata?.browseQuery {
                queryText = query
            } else {
                preparesBrowseQuery = true
                queryText = ""
                browse(connection)
            }
        } else {
            prepareTarget(object, connection: connection, mode: .query)
        }
    }

    func runQuery(_ connection: DatabaseConnectionSummary, appending: Bool = false) {
        guard !isLoading else { return }
        let continuation = appending ? nextContinuation : nil
        if appending, continuation == nil { return }
        do {
            let request: DatabaseQueryRequest
            if appending {
                guard let continuation, let lastQueryRequest else { return }
                request = Self.replay(lastQueryRequest, continuation: continuation)
            } else {
                request = try queryRequest(connection, continuation: nil)
                lastQueryRequest = request
            }
            execute(.query(request), connection: connection, appending: appending, mode: .query)
        } catch {
            resultMode = .query
            fail(error, generation: generation)
        }
    }

    private func execute(
        _ request: DatabaseBrokerCommandRequest, connection: DatabaseConnectionSummary,
        appending: Bool, mode: DatabaseDataResultMode
    ) {
        activeTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        resultMode = mode
        state = .loading
        let sender = sender
        activeTask = Task { [weak self] in
            do {
                let response = try await sender.send(request)
                try Task.checkCancellation()
                self?.finish(
                    response, connectionID: connection.id, generation: requestGeneration,
                    appending: appending, mode: mode)
            } catch is CancellationError {
            } catch { self?.fail(error, generation: requestGeneration) }
        }
    }

    func setSearchQueryOperation(
        _ operation: DatabaseSearchQueryOperation, connection: DatabaseConnectionSummary
    ) {
        guard searchQueryOperation != operation else { return }
        let replacesTemplate =
            selectedObject.map {
                queryText
                    == Self.defaultQueryText(
                        connection.product, object: $0, operation: searchQueryOperation)
            } == true
        searchQueryOperation = operation
        if replacesTemplate, let selectedObject {
            queryText = Self.defaultQueryText(
                connection.product, object: selectedObject, operation: operation)
        }
    }

    func loadNextPage(_ connection: DatabaseConnectionSummary) {
        if resultMode == .query {
            runQuery(connection, appending: true)
        } else {
            browse(connection, appending: true)
        }
    }

    func setPageSize(_ size: Int) {
        guard Self.pageSizeOptions.contains(size), pageSize != size else { return }
        pageSize = size
        resetBrowsePaging()
    }

    func selectRecord(at index: Int) {
        guard records.indices.contains(index) else { return }
        cancelEditor()
        selectedRecordIndex = selectedRecordIndex == index ? nil : index
        announcement(selectedRecordIndex == nil ? "Closed row details." : "Opened row details.")
    }

    func cancel() {
        preparesBrowseQuery = false
        activeTask?.cancel()
        activeTask = nil
        generation = UUID()
        if state == .loading { state = records.isEmpty ? .idle : .loaded }
    }

    func finishMutation(_ connection: DatabaseConnectionSummary) {
        cancelEditor()
        browse(connection)
    }

    func text(for value: DatabaseValue) -> String { Self.text(for: value) }

    func documentSource(_ record: DatabaseRecord) -> String? {
        try? DatabaseJSONDocumentCodec.encodeObject(
            record.fields.filter { $0.name != "_highlight" })
    }

    func value(named name: String, in record: DatabaseRecord) -> DatabaseValue {
        record.fields.first(where: { $0.name == name })?.value ?? .missing
    }

    private func prepareTarget(
        _ object: DatabaseObjectIdentifier, connection: DatabaseConnectionSummary,
        mode: DatabaseDataResultMode
    ) {
        let replacesTemplate =
            queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedObject.map {
                queryText
                    == Self.defaultQueryText(
                        connection.product, object: $0, operation: searchQueryOperation)
            } == true
        cancel()
        if selectedObject != object {
            objectFields = []
            clearFilters()
            clearSorts()
            cancelEditor()
        }
        resetResults()
        selectedObject = object
        targetText = object.path.joined(separator: ".")
        resultMode = mode
        if replacesTemplate {
            queryText = Self.defaultQueryText(
                connection.product, object: object, operation: searchQueryOperation)
        }
    }

    private func resetResults() {
        records = []
        fields = []
        selectedRecordIndex = nil
        nextContinuation = nil
        metadata = nil
        lastQueryRequest = nil
        browseQueryIsCurrent = false
        state = .idle
    }

    private func resetBrowsePaging() {
        browseQueryIsCurrent = false
        if isLoading { cancel() }
        nextContinuation = nil
    }

    private func finish(
        _ response: DatabaseBrokerCommandResponse, connectionID: DatabaseConnectionID,
        generation: UUID, appending: Bool, mode: DatabaseDataResultMode
    ) {
        guard self.generation == generation, activeConnectionID == connectionID else { return }
        activeTask = nil
        let page: DatabaseCore.DatabasePage<DatabaseRecord>
        switch (mode, response) {
        case (.browse, .browse(let result)):
            guard result.status != .failed, let payload = result.payload else {
                publishFailure(result.error?.message ?? "The data could not be loaded.")
                return
            }
            page = payload.page
        case (.query, .query(let result)):
            guard result.status != .failed, let payload = result.payload else {
                publishFailure(result.error?.message ?? "The data could not be loaded.")
                return
            }
            page = payload.page
        default:
            state = .failed("The database returned an unexpected data response.")
            return
        }
        if appending {
            let previousCount = records.count
            records.append(contentsOf: page.records)
            recordsAppendedFrom = previousCount
        } else {
            records = page.records
            selectedRecordIndex = nil
        }
        fields = page.fields
        if mode == .browse { objectFields = page.fields }
        nextContinuation = page.nextContinuation
        metadata = page.metadata
        browseQueryIsCurrent = mode == .browse && page.metadata.browseQuery != nil
        if preparesBrowseQuery {
            preparesBrowseQuery = false
            queryText = page.metadata.browseQuery ?? ""
        }
        state = .loaded
        announcement("Loaded \(page.records.count) database records.")
    }

    private func fail(_ error: Error, generation: UUID) {
        guard self.generation == generation else { return }
        activeTask = nil
        publishFailure(Self.message(for: error))
    }

    private func publishFailure(_ message: String) {
        state = .failed(message)
        announcement(message)
    }

    private static func message(for error: Error) -> String {
        if let input = error as? DatabaseDataWorkspaceInputError {
            switch input {
            case .invalidTarget(let message), .invalidQuery(let message),
                .invalidFilter(let message):
                return message
            }
        }
        if let client = error as? DatabaseBrokerCommandClientError {
            switch client {
            case .timedOut: return "The data request timed out."
            case .unavailable: return "The database service is unavailable."
            case .unsafePeer: return "The database service could not be verified."
            case .outcomeUnknown: return "The data request outcome could not be confirmed."
            case .invalidRequest: return "The database rejected this data request."
            }
        }
        return "The data could not be loaded."
    }

    private static func announce(_ message: String) { AccessibilityAnnouncement.post(message) }
}
