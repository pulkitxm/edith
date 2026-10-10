import DatabaseCore
import Foundation
import Observation

enum DatabaseWorkbenchMode: String, CaseIterable {
    case browse
    case query
    case structure

    var title: String {
        switch self {
        case .browse: "Browse"
        case .query: "Query"
        case .structure: "Structure"
        }
    }
}

@MainActor
@Observable
final class DatabaseTableTab: Identifiable {
    let id = UUID()
    let object: DatabaseObjectIdentifier
    let data: DatabaseDataWorkspaceModel
    let columns = DatabaseColumnsModel()
    let history = DatabaseQueryHistory()
    var hasOpenedQuery = false
    var mode = DatabaseWorkbenchMode.browse
    @ObservationIgnored var scrollOffset = CGPoint.zero

    init(object: DatabaseObjectIdentifier, data: DatabaseDataWorkspaceModel) {
        self.object = object
        self.data = data
    }

    func selectMode(_ next: DatabaseWorkbenchMode, connection: DatabaseConnectionSummary) {
        guard mode != next, !data.isLoading else { return }
        mode = next
        if next == .query, !hasOpenedQuery {
            hasOpenedQuery = true
            data.prepareQuery(object, connection: connection)
        } else if next == .browse, data.resultMode == .query {
            data.open(object, connection: connection)
        }
    }

    func runQuery(_ connection: DatabaseConnectionSummary) {
        guard !data.isLoading else { return }
        history.record(data.queryText, operation: data.searchQueryOperation)
        data.runQuery(connection)
    }

    func restoreQuery(_ entry: DatabaseQueryHistoryEntry, connection: DatabaseConnectionSummary) {
        guard !data.isLoading else { return }
        hasOpenedQuery = true
        mode = .query
        data.setSearchQueryOperation(entry.operation, connection: connection)
        data.queryText = entry.text
    }
}

@MainActor
@Observable
final class DatabaseTableTabsModel {
    private(set) var tabs: [DatabaseTableTab] = []
    private(set) var selectedID: UUID?
    private(set) var connectionID: DatabaseConnectionID?
    private let initialData: DatabaseDataWorkspaceModel
    private let makeData: @MainActor () -> DatabaseDataWorkspaceModel

    init(
        data: DatabaseDataWorkspaceModel? = nil,
        makeData: @escaping @MainActor () -> DatabaseDataWorkspaceModel = {
            DatabaseDataWorkspaceModel()
        }
    ) {
        initialData = data ?? makeData()
        self.makeData = makeData
    }

    var selected: DatabaseTableTab? { tabs.first { $0.id == selectedID } }
    var data: DatabaseDataWorkspaceModel { selected?.data ?? initialData }

    func prepare(for connection: DatabaseConnectionSummary?) {
        guard connectionID != connection?.id else { return }
        for tab in tabs { tab.data.cancel() }
        tabs = []
        selectedID = nil
        connectionID = connection?.id
        initialData.prepare(for: connection)
    }

    func open(_ object: DatabaseObjectIdentifier, connection: DatabaseConnectionSummary) {
        prepare(for: connection)
        if let existing = tabs.first(where: { $0.object == object }) {
            selectedID = existing.id
            return
        }
        let data = tabs.isEmpty ? initialData : makeData()
        data.prepare(for: connection)
        let tab = DatabaseTableTab(object: object, data: data)
        tabs.append(tab)
        selectedID = tab.id
        if data.selectedObject != object || data.state == .idle {
            data.open(object, connection: connection)
        }
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func finishMutation(target: DatabaseTargetIdentifier?, connection: DatabaseConnectionSummary) {
        guard let target, target.connectionID == connection.id,
            let tab = tabs.first(where: { $0.object == target.object })
        else { return }
        tab.data.finishMutation(connection)
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.data.cancel()
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { initialData.prepare(for: nil) }
    }
}
