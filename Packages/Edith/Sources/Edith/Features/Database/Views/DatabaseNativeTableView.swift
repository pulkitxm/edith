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
    let sorts: [DatabaseSort]
    let text: (DatabaseValue) -> String
    let select: (Int) -> Void
    let open: (Int) -> Void
    let rowIsEditable: (Int) -> Bool
    let canEdit: (Int, String) -> Bool
    let edit: (Int, String, String) -> Void
    let sort: (String, Bool) -> Void

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
        tableView.intercellSpacing = NSSize(width: 12, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.style = .plain
        tableView.backgroundColor = NSColor(background)
        tableView.selectionHighlightStyle = .regular
        tableView.headerView?.menu = nil
        tableView.headerView?.frame.size.height = 28
        tableView.setAccessibilityLabel("Database records")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(background)
        scrollView.borderType = .noBorder
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
        private var applyingSortDescriptors = false

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
                textField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
                cell.imageView?.image =
                    parent.records[row].identity == nil
                    ? nil
                    : NSImage(
                        systemSymbolName: "key.fill",
                        accessibilityDescription: parent.rowIsEditable(row)
                            ? "Editable row" : "Stable row key")
                cell.imageView?.contentTintColor =
                    tableView.selectedRow == row ? NSColor(parent.accent) : .tertiaryLabelColor
                textField.toolTip =
                    parent.records[row].identity == nil
                    ? "This row has no stable key"
                    : "This row has a stable key"
                textField.setAccessibilityLabel("Row \(row + 1)")
                textField.setAccessibilityValue(
                    parent.records[row].identity == nil ? "No stable key" : "Stable key")
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
                ? .monospacedSystemFont(ofSize: 11, weight: .light)
                : .monospacedSystemFont(ofSize: 11, weight: .regular)
            textField.toolTip = "\(field.displayName): \(rendered)"
            textField.setAccessibilityLabel(field.displayName)
            textField.setAccessibilityValue(rendered)
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
            rowView.alternatingColor = NSColor(parent.ink).withAlphaComponent(0.025)
            rowView.hoverColor = NSColor(parent.ink).withAlphaComponent(0.07)
            rowView.rowIndex = row
            return rowView
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard !applyingSortDescriptors,
                let field = interactedSortField(
                    oldDescriptors: oldDescriptors,
                    newDescriptors: tableView.sortDescriptors)
            else { return }
            parent.sort(field, NSEvent.modifierFlags.contains(.shift))
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
            applyHeaderPalette()
        }

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }
            let rowColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(Self.rowColumnIdentifier))
            rowColumn.title = "#"
            rowColumn.headerCell = makeHeaderCell(title: "#", alignment: .right)
            rowColumn.width = 50
            rowColumn.minWidth = 46
            rowColumn.maxWidth = 64
            rowColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(rowColumn)

            fieldNames = parent.fields.map { $0.path.segments.joined(separator: ".") }
            for field in parent.fields {
                let name = field.path.segments.joined(separator: ".")
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.title = field.displayName
                column.headerCell = makeHeaderCell(title: field.displayName)
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
            applyHeaderPalette()
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
            let descriptors = parent.sorts.compactMap { sort -> NSSortDescriptor? in
                let field = sort.field.segments.joined(separator: ".")
                guard fieldNames.contains(field) else { return nil }
                return NSSortDescriptor(
                    key: field,
                    ascending: sort.direction == .ascending)
            }
            if tableView.sortDescriptors != descriptors {
                applyingSortDescriptors = true
                defer { applyingSortDescriptors = false }
                tableView.sortDescriptors = descriptors
            }
        }

        private func interactedSortField(
            oldDescriptors: [NSSortDescriptor],
            newDescriptors: [NSSortDescriptor]
        ) -> String? {
            let oldSorts = sortableDescriptors(oldDescriptors)
            let newSorts = sortableDescriptors(newDescriptors)
            var oldDirections: [String: Bool] = [:]
            var newDirections: [String: Bool] = [:]
            for sort in oldSorts {
                oldDirections[sort.field] = sort.ascending
            }
            for sort in newSorts {
                newDirections[sort.field] = sort.ascending
            }
            if let added = newSorts.first(where: { oldDirections[$0.field] == nil }) {
                return added.field
            }
            if let changed = newSorts.first(where: {
                guard let previous = oldDirections[$0.field] else { return false }
                return previous != $0.ascending
            }) {
                return changed.field
            }
            if let removed = oldSorts.first(where: { newDirections[$0.field] == nil }) {
                return removed.field
            }
            let oldFields = oldSorts.map(\.field)
            let newFields = newSorts.map(\.field)
            guard oldFields != newFields else { return nil }
            return newSorts.enumerated().first(where: { index, sort in
                !oldFields.indices.contains(index) || oldFields[index] != sort.field
            })?.element.field ?? oldFields.first
        }

        private func sortableDescriptors(
            _ descriptors: [NSSortDescriptor]
        ) -> [(field: String, ascending: Bool)] {
            descriptors.compactMap { descriptor in
                guard let field = descriptor.key, fieldNames.contains(field) else { return nil }
                return (field, descriptor.ascending)
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
            textField.drawsBackground = false
            textField.delegate = self
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
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
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 11),
                imageView.heightAnchor.constraint(equalToConstant: 11),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func makeHeaderCell(
            title: String,
            alignment: NSTextAlignment = .left
        ) -> DatabaseNativeHeaderCell {
            let cell = DatabaseNativeHeaderCell(textCell: title)
            cell.alignment = alignment
            cell.lineBreakMode = .byTruncatingTail
            cell.font = .systemFont(ofSize: 11, weight: .medium)
            return cell
        }

        private func applyHeaderPalette() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                guard let cell = column.headerCell as? DatabaseNativeHeaderCell else { continue }
                cell.fillColor = NSColor(parent.background)
                cell.dividerColor = NSColor(parent.inkFaint).withAlphaComponent(0.2)
                cell.textColor = NSColor(parent.inkFaint)
            }
            tableView.headerView?.needsDisplay = true
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
    var alternatingColor = NSColor.labelColor.withAlphaComponent(0.025)
    var hoverColor = NSColor.labelColor.withAlphaComponent(0.07)
    var rowIndex = 0
    private var hovering = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
        if !rowIndex.isMultiple(of: 2) {
            alternatingColor.setFill()
            bounds.fill()
        }
        guard hovering else { return }
        hoverColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 1),
            xRadius: 4,
            yRadius: 4
        ).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 4,
            yRadius: 4
        )
        accentColor.withAlphaComponent(isEmphasized ? 0.2 : 0.11).setFill()
        path.fill()
        accentColor.withAlphaComponent(isEmphasized ? 0.42 : 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class DatabaseNativeHeaderCell: NSTableHeaderCell {
    var fillColor = NSColor.controlBackgroundColor
    var dividerColor = NSColor.separatorColor

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        fillColor.setFill()
        cellFrame.fill()
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 8, dy: 3), in: controlView)
        dividerColor.setFill()
        let dividerY = controlView.isFlipped ? cellFrame.maxY - 1 : cellFrame.minY
        NSRect(
            x: cellFrame.minX,
            y: dividerY,
            width: cellFrame.width,
            height: 1
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
