import EdithDatabase
import EdithKit
import Foundation
import Observation

struct DatabaseColumnPresentation: Identifiable, Equatable, Sendable {
    let field: DatabaseFieldDescriptor
    var isVisible: Bool
    var width: CGFloat?

    var id: DatabaseFieldPath { field.path }
}

@MainActor
@Observable
final class DatabaseColumnsModel {
    static let minimumWidth: CGFloat = 90
    static let maximumWidth: CGFloat = 520

    private(set) var columns: [DatabaseColumnPresentation] = []
    private(set) var connectionID: DatabaseConnectionID?
    private(set) var object: DatabaseObjectIdentifier?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistenceKey: String

    init(
        defaults: UserDefaults = SharedDefaults.store,
        persistenceKey: String = "database.columns.layouts.v1"
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
    }

    var orderedFields: [DatabaseFieldDescriptor] {
        columns.map(\.field)
    }

    var visibleFields: [DatabaseFieldDescriptor] {
        columns.compactMap { column in
            column.isVisible ? column.field : nil
        }
    }

    var visibleCount: Int {
        columns.count(where: \.isVisible)
    }

    var allFieldsVisible: Bool {
        !columns.isEmpty && columns.allSatisfy(\.isVisible)
    }

    func synchronize(
        connectionID: DatabaseConnectionID,
        object: DatabaseObjectIdentifier,
        fields: [DatabaseFieldDescriptor]
    ) {
        self.connectionID = connectionID
        self.object = object
        guard !fields.isEmpty else {
            columns = []
            return
        }
        let scope = DatabaseColumnsStoredScope(connectionID: connectionID, object: object)
        let stored = storedLayouts().layouts.first(where: { $0.scope == scope })
        columns = Self.mergedColumns(fields: fields, stored: stored?.columns ?? [])
        ensureVisibleColumn()
        persist()
    }

    func clear() {
        connectionID = nil
        object = nil
        columns = []
    }

    func isVisible(_ fieldID: DatabaseFieldPath) -> Bool {
        columns.first(where: { $0.id == fieldID })?.isVisible == true
    }

    func canHide(_ fieldID: DatabaseFieldPath) -> Bool {
        guard let column = columns.first(where: { $0.id == fieldID }), column.isVisible else {
            return false
        }
        return visibleCount > 1
    }

    func setVisible(_ isVisible: Bool, for fieldID: DatabaseFieldPath) {
        guard let index = columns.firstIndex(where: { $0.id == fieldID }),
            columns[index].isVisible != isVisible
        else { return }
        if !isVisible, visibleCount == 1 { return }
        columns[index].isVisible = isVisible
        persist()
    }

    func toggleVisibility(_ fieldID: DatabaseFieldPath) {
        guard let column = columns.first(where: { $0.id == fieldID }) else { return }
        setVisible(!column.isVisible, for: fieldID)
    }

    func showAll() {
        guard columns.contains(where: { !$0.isVisible }) else { return }
        for index in columns.indices {
            columns[index].isVisible = true
        }
        persist()
    }

    func hideAll() {
        guard let keeper = columns.first(where: \.isVisible)?.id ?? columns.first?.id else {
            return
        }
        let changed = columns.contains { column in
            column.isVisible != (column.id == keeper)
        }
        guard changed else { return }
        for index in columns.indices {
            columns[index].isVisible = columns[index].id == keeper
        }
        persist()
    }

    func moveField(_ fieldID: DatabaseFieldPath, to destinationIndex: Int) {
        guard let sourceIndex = columns.firstIndex(where: { $0.id == fieldID }),
            columns.count > 1
        else { return }
        let boundedDestination = min(max(destinationIndex, 0), columns.count - 1)
        guard sourceIndex != boundedDestination else { return }
        let column = columns.remove(at: sourceIndex)
        columns.insert(column, at: boundedDestination)
        persist()
    }

    func width(for fieldID: DatabaseFieldPath) -> CGFloat? {
        columns.first(where: { $0.id == fieldID })?.width
    }

    func setWidth(_ width: CGFloat, for fieldID: DatabaseFieldPath) {
        guard width.isFinite,
            let index = columns.firstIndex(where: { $0.id == fieldID })
        else { return }
        let boundedWidth = min(max(width, Self.minimumWidth), Self.maximumWidth)
        guard columns[index].width != boundedWidth else { return }
        columns[index].width = boundedWidth
        persist()
    }

    private func ensureVisibleColumn() {
        guard !columns.isEmpty, !columns.contains(where: \.isVisible) else { return }
        columns[0].isVisible = true
    }

    private func persist() {
        guard let connectionID, let object else { return }
        let scope = DatabaseColumnsStoredScope(connectionID: connectionID, object: object)
        var stored = storedLayouts()
        let layout = DatabaseColumnsStoredLayout(
            scope: scope,
            columns: columns.map { column in
                DatabaseColumnsStoredColumn(
                    field: column.id,
                    isVisible: column.isVisible,
                    width: column.width.map(Double.init))
            })
        if let index = stored.layouts.firstIndex(where: { $0.scope == scope }) {
            if layout.columns.isEmpty {
                stored.layouts.remove(at: index)
            } else {
                stored.layouts[index] = layout
            }
        } else if !layout.columns.isEmpty {
            stored.layouts.append(layout)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: persistenceKey)
    }

    private func storedLayouts() -> DatabaseColumnsStoredLayouts {
        guard let data = defaults.data(forKey: persistenceKey),
            let stored = try? JSONDecoder().decode(DatabaseColumnsStoredLayouts.self, from: data),
            stored.version == DatabaseColumnsStoredLayouts.currentVersion
        else {
            return DatabaseColumnsStoredLayouts()
        }
        return stored
    }

    private static func mergedColumns(
        fields: [DatabaseFieldDescriptor],
        stored: [DatabaseColumnsStoredColumn]
    ) -> [DatabaseColumnPresentation] {
        var descriptors: [DatabaseFieldPath: DatabaseFieldDescriptor] = [:]
        var sourceOrder: [DatabaseFieldPath] = []
        for field in fields where descriptors[field.path] == nil {
            descriptors[field.path] = field
            sourceOrder.append(field.path)
        }
        var storedByField: [DatabaseFieldPath: DatabaseColumnsStoredColumn] = [:]
        var order: [DatabaseFieldPath] = []
        for column in stored where descriptors[column.field] != nil {
            if storedByField[column.field] == nil {
                storedByField[column.field] = column
                order.append(column.field)
            }
        }
        order.append(contentsOf: sourceOrder.filter { storedByField[$0] == nil })
        return order.compactMap { fieldID -> DatabaseColumnPresentation? in
            guard let field = descriptors[fieldID] else { return nil }
            let storedColumn = storedByField[fieldID]
            let width: CGFloat? = storedColumn?.width.flatMap { storedWidth -> CGFloat? in
                guard storedWidth.isFinite else { return nil }
                return min(
                    max(CGFloat(storedWidth), Self.minimumWidth),
                    Self.maximumWidth)
            }
            return DatabaseColumnPresentation(
                field: field,
                isVisible: storedColumn?.isVisible ?? true,
                width: width)
        }
    }
}

private struct DatabaseColumnsStoredLayouts: Codable {
    static let currentVersion = 1

    let version: Int
    var layouts: [DatabaseColumnsStoredLayout]

    init(
        version: Int = currentVersion,
        layouts: [DatabaseColumnsStoredLayout] = []
    ) {
        self.version = version
        self.layouts = layouts
    }
}

private struct DatabaseColumnsStoredLayout: Codable {
    let scope: DatabaseColumnsStoredScope
    var columns: [DatabaseColumnsStoredColumn]
}

private struct DatabaseColumnsStoredScope: Codable, Equatable {
    let connectionID: DatabaseConnectionID
    let object: DatabaseObjectIdentifier
}

private struct DatabaseColumnsStoredColumn: Codable {
    let field: DatabaseFieldPath
    let isVisible: Bool
    let width: Double?
}
