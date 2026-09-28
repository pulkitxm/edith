import AppKit
import EdithDatabase
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized)
struct DatabaseTableUpdateTests {
    @Test func appendingPagesKeepsVisibleCellsAndRefreshReplacesCachedValues() throws {
        _ = TestWindowHost.application
        let records = (0..<100).map { record("sample \($0)") }
        let host = NSHostingView(rootView: table(records: records, revision: 1))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            host.layoutSubtreeIfNeeded()
        }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        settle()
        let native = try #require(findTable(host))
        let cell = try #require(
            native.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.stringValue == "sample 0")
        var next = table(records: records + [record("appended")], revision: 2)
        next.appendedFrom = 100
        host.rootView = next
        settle()
        #expect(native.numberOfRows == 101)
        #expect(native.view(atColumn: 1, row: 0, makeIfNecessary: false) === cell)
        host.rootView = table(records: [record("refreshed")], revision: 3)
        settle()
        #expect(native.numberOfRows == 1)
        let refreshed = try #require(
            native.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(refreshed.textField?.stringValue == "refreshed")
    }

    @Test func onlyConsecutiveAppendRevisionsReuseVisibleRows() {
        var current = table(records: [record("first")], revision: 4)
        let coordinator = current.makeCoordinator()
        coordinator.hasLoadedData = true
        var next = table(records: [record("first"), record("second")], revision: 5)
        next.appendedFrom = 1
        #expect(coordinator.needsReload(next))
        #expect(coordinator.canAppend(next))
        next.contentRevision = 6
        #expect(!coordinator.canAppend(next))
        next.contentRevision = 5
        next.appendedFrom = nil
        #expect(!coordinator.canAppend(next))
        next.appendedFrom = 1
        next.editingEnabled = true
        #expect(!coordinator.canAppend(next))
        current.isActive = false
        #expect(!coordinator.needsReload(current))
    }

    @Test func schemaMetadataChangesRebuildHeadersAndSortability() throws {
        _ = TestWindowHost.application
        let current = table(records: [record("first")], revision: 1)
        let coordinator = current.makeCoordinator()
        let native = NSTableView()
        coordinator.tableView = native
        coordinator.rebuildColumns()
        #expect(native.tableColumns[1].title == "Name")
        coordinator.parent = table(
            records: [record("first")], revision: 1,
            field: Self.field(title: "Renamed", sortable: false))
        coordinator.rebuildColumnsIfNeeded()
        #expect(native.tableColumns[1].title == "Renamed")
        #expect(native.tableColumns[1].sortDescriptorPrototype == nil)
    }

    @Test func editingLoadsTheFullUntruncatedValue() throws {
        _ = TestWindowHost.application
        let full = String(repeating: "sample\n", count: 200)
        var committed: String?
        var current = table(records: [record(full)], revision: 1)
        current = editableTable(current, edit: { _, _, text in committed = text })
        let coordinator = current.makeCoordinator()
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier("name")
        field.tag = 0
        field.stringValue = full
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(committed == nil)
        field.stringValue = full + "edited"
        coordinator.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(committed == full + "edited")
    }

    @Test func nativeFieldEditorReceivesFullValue() throws {
        _ = TestWindowHost.application
        let full = String(repeating: "sample", count: 200)
        let host = NSHostingView(rootView: table(records: [record(full)], revision: 1))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        let native = try #require(findTable(host))
        let cell = try #require(
            native.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let field = try #require(cell.textField)
        field.selectText(nil)
        let editor = try #require(field.currentEditor())
        #expect(editor.string == full)
    }

    private func record(_ value: String) -> DatabaseRecord {
        DatabaseRecord(fields: [DatabaseObjectField(name: "name", value: .string(value))])
    }

    private func table(
        records: [DatabaseRecord], revision: Int, field: DatabaseFieldDescriptor = Self.field()
    ) -> DatabaseNativeTableView {
        DatabaseNativeTableView(
            accent: .orange, background: .black, grid: .gray, ink: .white, inkFaint: .gray,
            fields: [field], records: records, selectedIndex: nil, sorts: [],
            nextContinuation: nil, isLoading: false, columnWidth: { _ in nil },
            text: {
                if case .string(let text) = $0 { return text }; return ""
            },
            loadMore: {}, select: { _ in }, open: { _ in }, rowIsEditable: { _ in true },
            canEdit: { _, _ in true }, edit: { _, _, _ in }, sort: { _, _ in },
            resizeColumn: { _, _ in }, contentRevision: revision)
    }

    private func editableTable(
        _ table: DatabaseNativeTableView, edit: @escaping (Int, String, String) -> Void
    ) -> DatabaseNativeTableView {
        DatabaseNativeTableView(
            accent: table.accent, background: table.background, grid: table.grid,
            ink: table.ink, inkFaint: table.inkFaint, fields: table.fields, records: table.records,
            selectedIndex: nil, sorts: [], nextContinuation: nil, isLoading: false,
            columnWidth: { _ in nil }, text: table.text, loadMore: {}, select: { _ in },
            open: { _ in }, rowIsEditable: { _ in true }, canEdit: { _, _ in true },
            edit: edit, sort: { _, _ in }, resizeColumn: { _, _ in }, contentRevision: 1)
    }

    nonisolated static func field(title: String = "Name", sortable: Bool = true)
        -> DatabaseFieldDescriptor
    {
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("name"), displayName: title, typeName: "text",
            isNullable: true, isSortable: sortable, isFilterable: true)
    }
}
