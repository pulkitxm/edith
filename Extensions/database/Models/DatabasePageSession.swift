import DatabaseCore
import Foundation
import Observation

@MainActor
@Observable
final class DatabasePageSession {
    var focusedConnectionID: DatabaseConnectionID?
    let page = DatabasePageModel()
    let connections = DatabaseConnectionWorkspaceModel()
    let management = DatabaseConnectionManagementModel()
    let tables = DatabaseTableTabsModel()
    let objects = DatabaseObjectExplorerModel()
    let workspace = DatabaseWorkspaceModel()
    func shutdown() {
        objects.cancel()
        tables.data.cancel()
        for tab in tables.tabs { tab.data.cancel() }
        workspace.shutdown()
        page.loading.cancel()
    }
}
