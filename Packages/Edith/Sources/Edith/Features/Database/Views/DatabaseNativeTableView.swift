import AppKit
import EdithDatabase
import SwiftUI

struct DatabaseNativeTableView: NSViewRepresentable {
    let accent: Color
    let background: Color
    let grid: Color
    let ink: Color
    let inkFaint: Color
    let fields: [DatabaseFieldDescriptor]
    let records: [DatabaseRecord]
    let selectedIndex: Int?
    let sortField: String
    let sortDirection: DatabaseSortDirection
    let text: (DatabaseValue) -> String
    let select: (Int) -> Void
    let open: (Int) -> Void
    let canEdit: (Int, String) -> Bool
    let edit: (Int, String, String) -> Void
    let sort: (String, DatabaseSortDirection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.openSelectedRow)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 8, height: 1)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = NSColor(grid)
        tableView.style = .plain
        tableView.backgroundColor = NSColor(background)
        tableView.headerView?.menu = nil

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(background)
        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyPalette(to: scrollView)
        context.coordinator.rebuildColumnsIfNeeded()
        context.coordinator.tableView?.reloadData()
        context.coordinator.reloadSelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
        NSTextFieldDelegate
    {
        var parent: DatabaseNativeTableView
        weak var tableView: NSTableView?
        private var fieldNames: [String] = []
        private var applyingSelection = false

        init(parent: DatabaseNativeTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.records.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard parent.records.indices.contains(row), let tableColumn else { return nil }
            let identifier = tableColumn.identifier
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeCell(identifier: identifier)
            guard let textField = cell.textField else { return cell }
            if identifier.rawValue == Self.rowColumnIdentifier {
                textField.stringValue = (row + 1).formatted()
                textField.alignment = .right
                textField.textColor = NSColor(parent.inkFaint)
                textField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
                cell.imageView?.image =
                    parent.records[row].identity == nil
                    ? nil
                    : NSImage(
                        systemSymbolName: "key.fill", accessibilityDescription: "Editable row")
                cell.imageView?.contentTintColor =
                    tableView.selectedRow == row ? NSColor(parent.accent) : .tertiaryLabelColor
                textField.toolTip =
                    parent.records[row].identity == nil
                    ? "This row has no stable key"
                    : "This row has a stable key"
                return cell
            }
            guard
                let field = parent.fields.first(where: {
                    $0.path.segments.joined(separator: ".") == identifier.rawValue
                })
            else { return cell }
            let value =
                parent.records[row].fields.first(where: { $0.name == identifier.rawValue })?
                .value ?? .missing
            let rendered = bounded(parent.text(value))
            textField.stringValue = rendered
            textField.alignment = .left
            textField.textColor = NSColor(value.isAbsent ? parent.inkFaint : parent.ink)
            textField.font =
                value.isAbsent
                ? .monospacedSystemFont(ofSize: 10.5, weight: .light)
                : .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            textField.toolTip = "\(field.displayName): \(rendered)"
            textField.tag = row
            textField.isEditable = parent.canEdit(row, identifier.rawValue)
            textField.isSelectable = true
            return cell
        }

        func tableView(
            _ tableView: NSTableView,
            shouldEdit tableColumn: NSTableColumn?,
            row: Int
        ) -> Bool {
            guard let name = tableColumn?.identifier.rawValue,
                name != Self.rowColumnIdentifier
            else { return false }
            return parent.canEdit(row, name)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let row = tableView?.selectedRow, row >= 0 else { return }
            parent.select(row)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = DatabaseNativeRowView()
            rowView.accentColor = NSColor(parent.accent)
            return rowView
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = tableView.sortDescriptors.first,
                let field = descriptor.key,
                fieldNames.contains(field)
            else { return }
            parent.sort(field, descriptor.ascending ? .ascending : .descending)
        }

        @objc func openSelectedRow() {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            let row = tableView.clickedRow
            let column = tableView.clickedColumn
            if column > 0,
                parent.canEdit(row, tableView.tableColumns[column].identifier.rawValue)
            {
                tableView.editColumn(column, row: row, with: nil, select: true)
                return
            }
            parent.open(row)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField,
                let name = textField.identifier?.rawValue,
                parent.canEdit(textField.tag, name)
            else { return }
            let current =
                parent.records[textField.tag].fields.first(where: { $0.name == name })?
                .value ?? .missing
            guard textField.stringValue != bounded(parent.text(current)) else { return }
            parent.edit(textField.tag, name, textField.stringValue)
        }

        func rebuildColumnsIfNeeded() {
            let names = parent.fields.map { $0.path.segments.joined(separator: ".") }
            guard names != fieldNames else {
                updateSortDescriptors()
                return
            }
            rebuildColumns()
        }

        func applyPalette(to scrollView: NSScrollView) {
            let background = NSColor(parent.background)
            scrollView.backgroundColor = background
            tableView?.backgroundColor = background
            tableView?.gridColor = NSColor(parent.grid)
        }

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }
            let rowColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(Self.rowColumnIdentifier))
            rowColumn.title = "#"
            rowColumn.width = 58
            rowColumn.minWidth = 52
            rowColumn.maxWidth = 72
            rowColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(rowColumn)

            fieldNames = parent.fields.map { $0.path.segments.joined(separator: ".") }
            for field in parent.fields {
                let name = field.path.segments.joined(separator: ".")
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.title = field.displayName
                column.width = initialWidth(for: field)
                column.minWidth = 90
                column.maxWidth = 520
                column.resizingMask = .userResizingMask
                if field.isSortable {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                }
                tableView.addTableColumn(column)
            }
            updateSortDescriptors()
        }

        func reloadSelection() {
            guard let tableView else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if let selectedIndex = parent.selectedIndex,
                parent.records.indices.contains(selectedIndex)
            {
                if tableView.selectedRow != selectedIndex {
                    tableView.selectRowIndexes(
                        IndexSet(integer: selectedIndex), byExtendingSelection: false)
                }
            } else if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
        }

        private func updateSortDescriptors() {
            guard let tableView else { return }
            let descriptors: [NSSortDescriptor]
            if fieldNames.contains(parent.sortField) {
                descriptors = [
                    NSSortDescriptor(
                        key: parent.sortField,
                        ascending: parent.sortDirection == .ascending)
                ]
            } else {
                descriptors = []
            }
            if tableView.sortDescriptors != descriptors {
                tableView.sortDescriptors = descriptors
            }
        }

        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            if identifier.rawValue == Self.rowColumnIdentifier {
                return makeIdentityCell(identifier: identifier)
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 1
            textField.delegate = self
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func makeIdentityCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView
        {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            let textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 11),
                imageView.heightAnchor.constraint(equalToConstant: 11),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 3),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func initialWidth(for field: DatabaseFieldDescriptor) -> CGFloat {
            let titleWidth = CGFloat(max(field.displayName.count, field.typeName.count) * 8 + 32)
            switch field.typeName.lowercased() {
            case let type where type.contains("bool"):
                return max(90, titleWidth)
            case let type where type.contains("int") || type.contains("numeric"):
                return max(120, titleWidth)
            case let type where type.contains("date") || type.contains("time"):
                return max(180, titleWidth)
            default:
                return max(160, titleWidth)
            }
        }

        private func bounded(_ value: String) -> String {
            let compact = value.replacingOccurrences(of: "\n", with: " ")
            guard compact.count > 512 else { return compact }
            return "\(compact.prefix(511))…"
        }

        private static let rowColumnIdentifier = "__database_row_number"
    }
}

private final class DatabaseNativeRowView: NSTableRowView {
    var accentColor = NSColor.controlAccentColor

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        accentColor.withAlphaComponent(isEmphasized ? 0.24 : 0.14).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 4,
            yRadius: 4
        ).fill()
    }
}

private extension DatabaseValue {
    var isAbsent: Bool {
        switch self {
        case .missing, .null: true
        default: false
        }
    }
}
