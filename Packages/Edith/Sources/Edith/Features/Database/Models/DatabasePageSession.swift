import Foundation

@MainActor
final class DatabasePageSession {
    let page = DatabasePageModel()
    let connections = DatabaseConnectionWorkspaceModel()
    let management = DatabaseConnectionManagementModel()
    let tables = DatabaseTableTabsModel()
    let objects = DatabaseObjectExplorerModel()
    let workspace = DatabaseWorkspaceModel()
}
