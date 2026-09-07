import Foundation
import Testing

@testable import Edith
@testable import EdithDatabase

@MainActor
@Suite("Database columns model")
struct DatabaseColumnsModelTests {
    @Test("Columns start visible in source order")
    func defaultLayout() {
        let defaults = Self.defaults()
        let model = DatabaseColumnsModel(defaults: defaults)

        model.synchronize(
            connectionID: DatabaseConnectionID(),
            object: Self.object("orders"),
            fields: Self.fields("id", "name", "status"))

        #expect(model.orderedFields.map(\.displayName) == ["id", "name", "status"])
        #expect(model.visibleFields == model.orderedFields)
        #expect(model.visibleCount == 3)
        #expect(model.allFieldsVisible)
        #expect(model.columns.allSatisfy { $0.width == nil })
    }

    @Test("Visibility controls always preserve one visible column")
    func visibilityControls() {
        let model = DatabaseColumnsModel(defaults: Self.defaults())
        let fields = Self.fields("id", "name", "status")
        model.synchronize(
            connectionID: DatabaseConnectionID(),
            object: Self.object("orders"),
            fields: fields)

        model.setVisible(false, for: fields[0].path)
        #expect(model.visibleFields.map(\.displayName) == ["name", "status"])
        #expect(!model.isVisible(fields[0].path))
        #expect(!model.canHide(fields[0].path))

        model.hideAll()
        #expect(model.visibleFields.map(\.displayName) == ["name"])
        #expect(!model.canHide(fields[1].path))
        model.toggleVisibility(fields[1].path)
        #expect(model.visibleFields.map(\.displayName) == ["name"])

        model.showAll()
        #expect(model.visibleFields == model.orderedFields)
        #expect(model.allFieldsVisible)
    }

    @Test("Order visibility and widths persist per connection and object")
    func scopedPersistence() {
        let defaults = Self.defaults()
        let connectionID = DatabaseConnectionID()
        let object = Self.object("orders")
        let fields = Self.fields("id", "name", "status")
        let first = DatabaseColumnsModel(defaults: defaults)
        first.synchronize(connectionID: connectionID, object: object, fields: fields)
        first.moveField(fields[2].path, to: 0)
        first.setVisible(false, for: fields[1].path)
        first.setWidth(244, for: fields[2].path)
        first.synchronize(connectionID: connectionID, object: object, fields: [])
        #expect(first.columns.isEmpty)
        first.synchronize(connectionID: connectionID, object: object, fields: fields)
        #expect(first.orderedFields.map(\.displayName) == ["status", "id", "name"])

        let restored = DatabaseColumnsModel(defaults: defaults)
        restored.synchronize(connectionID: connectionID, object: object, fields: fields)
        #expect(restored.orderedFields.map(\.displayName) == ["status", "id", "name"])
        #expect(restored.visibleFields.map(\.displayName) == ["status", "id"])
        #expect(restored.width(for: fields[2].path) == 244)

        restored.synchronize(
            connectionID: connectionID,
            object: Self.object("customers"),
            fields: fields)
        #expect(restored.orderedFields.map(\.displayName) == ["id", "name", "status"])
        #expect(restored.allFieldsVisible)
        #expect(restored.width(for: fields[2].path) == nil)

        restored.synchronize(
            connectionID: DatabaseConnectionID(),
            object: object,
            fields: fields)
        #expect(restored.orderedFields.map(\.displayName) == ["id", "name", "status"])
        #expect(restored.allFieldsVisible)
    }

    @Test("Synchronization prunes stale fields and appends new fields")
    func staleFieldPruning() {
        let defaults = Self.defaults()
        let connectionID = DatabaseConnectionID()
        let object = Self.object("orders")
        let original = Self.fields("id", "name", "legacy")
        let first = DatabaseColumnsModel(defaults: defaults)
        first.synchronize(connectionID: connectionID, object: object, fields: original)
        first.moveField(original[2].path, to: 0)
        first.hideAll()
        first.setWidth(320, for: original[2].path)

        let current = Self.fields("id", "name", "status")
        first.synchronize(connectionID: connectionID, object: object, fields: current)
        #expect(first.orderedFields.map(\.displayName) == ["id", "name", "status"])
        #expect(first.visibleFields.map(\.displayName) == ["status"])
        #expect(first.width(for: original[2].path) == nil)

        let reintroduced = Self.fields("id", "name", "legacy", "status")
        let restored = DatabaseColumnsModel(defaults: defaults)
        restored.synchronize(
            connectionID: connectionID,
            object: object,
            fields: reintroduced)
        #expect(restored.orderedFields.map(\.displayName) == ["id", "name", "status", "legacy"])
        #expect(restored.isVisible(original[2].path))
        #expect(restored.width(for: original[2].path) == nil)
    }

    @Test("Widths are bounded and clear resets transient state")
    func boundedWidthsAndClear() {
        let model = DatabaseColumnsModel(defaults: Self.defaults())
        let fields = Self.fields("id", "name")
        model.synchronize(
            connectionID: DatabaseConnectionID(),
            object: Self.object("orders"),
            fields: fields)

        model.setWidth(10, for: fields[0].path)
        model.setWidth(2_000, for: fields[1].path)
        #expect(model.width(for: fields[0].path) == DatabaseColumnsModel.minimumWidth)
        #expect(model.width(for: fields[1].path) == DatabaseColumnsModel.maximumWidth)
        model.setWidth(.nan, for: fields[0].path)
        #expect(model.width(for: fields[0].path) == DatabaseColumnsModel.minimumWidth)

        model.clear()
        #expect(model.columns.isEmpty)
        #expect(model.connectionID == nil)
        #expect(model.object == nil)
    }

    private static func defaults() -> UserDefaults {
        let name = "database-columns-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func object(_ name: String) -> DatabaseObjectIdentifier {
        DatabaseObjectIdentifier(kind: .table, path: ["public", name])
    }

    private static func fields(_ names: String...) -> [DatabaseFieldDescriptor] {
        names.map { name in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath(name),
                displayName: name,
                typeName: name == "id" ? "BIGINT" : "TEXT",
                isNullable: name != "id",
                isSortable: true,
                isFilterable: true)
        }
    }
}
