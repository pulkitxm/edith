import AppKit
import DatabaseCore
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
    let nextContinuation: DatabaseContinuationToken?
    let isLoading: Bool
    let columnWidth: (DatabaseFieldPath) -> CGFloat?
    let text: (DatabaseValue) -> String
    let loadMore: () -> Void
    let select: (Int) -> Void
    let open: (Int) -> Void
    let rowIsEditable: (Int) -> Bool
    let canEdit: (Int, String) -> Bool
    let edit: (Int, String, String) -> Void
    let sort: (String, Bool) -> Void
    let resizeColumn: (DatabaseFieldPath, CGFloat) -> Void
    var contentRevision: Int? = nil
    var appendedFrom: Int? = nil
    var editingEnabled = false
    var isActive = true
    var scale = 1.0
    var scrollOffset = CGPoint.zero
    var saveScrollOffset: (CGPoint) -> Void = { _ in }

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
        tableView.rowHeight = DatabaseTableMetrics.points(
            DatabaseTableMetrics.rowHeight, scale: scale)
        tableView.intercellSpacing = NSSize(
            width: DatabaseTableMetrics.points(DatabaseTableMetrics.intercellWidth, scale: scale),
            height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.style = .plain
        tableView.backgroundColor = NSColor(background)
        tableView.selectionHighlightStyle = .regular
        tableView.headerView?.menu = nil
        tableView.headerView?.frame.size.height = DatabaseTableMetrics.points(
            DatabaseTableMetrics.headerHeight, scale: scale)
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
        context.coordinator.observeScrolling(in: scrollView)
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.isUpdating = true
        let reload = context.coordinator.needsReload(self)
        let append = context.coordinator.canAppend(self)
        if reload && !append { context.coordinator.projection.invalidateRows() }
        context.coordinator.parent = self
        let scaledScroll = context.coordinator.consumeScaleChange(in: scrollView)
        let continuationChanged = context.coordinator.continuationDidChange(nextContinuation)
        context.coordinator.applyPalette(to: scrollView)
        context.coordinator.rebuildColumnsIfNeeded()
        context.coordinator.applyColumnWidths()
        if reload {
            if append {
                context.coordinator.tableView?.noteNumberOfRowsChanged()
            } else {
                context.coordinator.tableView?.reloadData()
            }
            context.coordinator.hasLoadedData = true
        }
        context.coordinator.reloadSelection()
        let scrollTarget = scaledScroll ?? scrollOffset
        if scaledScroll != nil { saveScrollOffset(scrollTarget) }
        if reload || scaledScroll != nil || scrollView.contentView.bounds.origin != scrollTarget {
            scrollView.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: scrollTarget)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        context.coordinator.isUpdating = false
        if continuationChanged {
            let coordinator = context.coordinator
            Task { @MainActor [weak coordinator] in
                await Task.yield()
                coordinator?.loadMoreIfNeeded()
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObservingScrolling(in: scrollView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource,
        NSTextFieldDelegate
    {
        var parent: DatabaseNativeTableView
        var isUpdating = false
        var hasLoadedData = false
        var projection = DatabaseGridProjection()

        func canAppend(_ next: DatabaseNativeTableView) -> Bool {
            guard hasLoadedData, let revision = parent.contentRevision,
                next.contentRevision == revision &+ 1,
                next.appendedFrom == parent.records.count,
                next.records.count > parent.records.count
            else { return false }
            return next.fields == parent.fields && next.editingEnabled == parent.editingEnabled
                && next.accent == parent.accent && next.background == parent.background
                && next.ink == parent.ink && next.inkFaint == parent.inkFaint
        }

        func needsReload(_ next: DatabaseNativeTableView) -> Bool {
            let recordsChanged =
                next.contentRevision.map { $0 != parent.contentRevision }
                ?? (next.records != parent.records)
            return !hasLoadedData || recordsChanged || next.fields != parent.fields
                || next.editingEnabled != parent.editingEnabled
                || next.accent != parent.accent || next.background != parent.background
                || next.ink != parent.ink || next.inkFaint != parent.inkFaint
        }

        weak var tableView: NSTableView?
        private var fieldNames: [String] = []
        private var columnFields: [DatabaseFieldDescriptor] = []
        private var columnsByName: [String: NSTableColumn] = [:]
        private var applyingSelection = false
        private var applyingSortDescriptors = false
        private var applyingColumnWidths = false
        private var observedContinuation: DatabaseContinuationToken?
        private var paginationGate = DatabaseTablePaginationGate()
        private var appliedScale: Double

        init(parent: DatabaseNativeTableView) {
            self.parent = parent
            appliedScale = parent.scale
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.records.count
        }

        func observeScrolling(in scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(liveScrollWillStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView)
        }

        func stopObservingScrolling(in scrollView: NSScrollView) {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
            NotificationCenter.default.removeObserver(
                self,
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView)
        }

        func continuationDidChange(_ continuation: DatabaseContinuationToken?) -> Bool {
            defer { observedContinuation = continuation }
            return continuation != observedContinuation
        }

        @objc private func visibleBoundsChanged() {
            guard !isUpdating else { return }
            if let origin = tableView?.enclosingScrollView?.contentView.bounds.origin {
                parent.saveScrollOffset(origin)
            }
            loadMoreIfNeeded()
        }

        @objc private func liveScrollWillStart() {
            paginationGate.rearm()
            loadMoreIfNeeded()
        }

        func loadMoreIfNeeded() {
            guard parent.isActive, let tableView else { return }
            guard
                paginationGate.shouldLoadMore(
                    continuation: parent.nextContinuation,
                    isLoading: parent.isLoading,
                    visibleMaxY: tableView.visibleRect.maxY,
                    contentMaxY: tableView.bounds.maxY,
                    rowHeight: tableView.rowHeight)
            else { return }
            parent.loadMore()
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
            textField.toolTip = nil
            if identifier.rawValue == Self.rowColumnIdentifier {
                textField.stringValue = (row + 1).formatted()
                textField.alignment = .right
                textField.textColor = NSColor(parent.inkFaint)
                textField.font = .monospacedDigitSystemFont(
                    ofSize: DatabaseTableMetrics.points(
                        DatabaseTableMetrics.indexFont, scale: parent.scale), weight: .medium)
                for constraint in cell.imageView?.constraints ?? []
                where constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                    constraint.constant = DatabaseTableMetrics.points(
                        DatabaseTableMetrics.keySide, scale: parent.scale)
                }
                cell.imageView?.image =
                    parent.records[row].identity == nil
                    ? nil
                    : NSImage(
                        systemSymbolName: "key.fill",
                        accessibilityDescription: parent.rowIsEditable(row)
                            ? "Editable row" : "Stable row key")
                cell.imageView?.contentTintColor =
                    tableView.selectedRow == row ? NSColor(parent.accent) : .tertiaryLabelColor
                textField.setAccessibilityLabel("Row \(row + 1)")
                textField.setAccessibilityValue(
                    parent.records[row].identity == nil ? "No stable key" : "Stable key")
                return cell
            }
            guard let field = projection.fieldsByName[identifier.rawValue]
            else { return cell }
            let value = projection.value(
                named: identifier.rawValue, row: row, records: parent.records)
            let fullText = parent.text(value)
            let rendered = bounded(fullText)
            textField.stringValue = rendered
            (textField as? DatabaseNativeValueField)?.editingValue = fullText
            textField.alignment = .left
            textField.textColor = NSColor(value.isAbsent ? parent.inkFaint : parent.ink)
            let bodySize = DatabaseTableMetrics.points(
                DatabaseTableMetrics.bodyFont, scale: parent.scale)
            textField.font =
                value.isAbsent
                ? .monospacedSystemFont(ofSize: bodySize, weight: .light)
                : .monospacedSystemFont(ofSize: bodySize, weight: .regular)
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
            rowView.baseColor = NSColor(parent.background)
            rowView.alternatingColor = NSColor(parent.ink).withAlphaComponent(0.025)
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

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !applyingColumnWidths,
                let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                column.identifier.rawValue != Self.rowColumnIdentifier,
                let field = parent.fields.first(where: {
                    $0.path.segments.joined(separator: ".") == column.identifier.rawValue
                })
            else { return }
            parent.resizeColumn(
                field.path, DatabaseTableMetrics.logical(column.width, scale: parent.scale))
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
                parent.records.indices.contains(textField.tag),
                parent.canEdit(textField.tag, name)
            else { return }
            let current =
                parent.records[textField.tag].fields.first(where: { $0.name == name })?
                .value ?? .missing
            guard textField.stringValue != parent.text(current) else { return }
            parent.edit(textField.tag, name, textField.stringValue)
        }

        func rebuildColumnsIfNeeded() {
            guard parent.fields != columnFields else {
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
            projection.setFields(parent.fields)
            columnFields = parent.fields
            for column in tableView.tableColumns {
                tableView.removeTableColumn(column)
            }
            columnsByName.removeAll(keepingCapacity: true)
            let rowColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(Self.rowColumnIdentifier))
            rowColumn.title = "#"
            rowColumn.headerCell = makeHeaderCell(title: "#", alignment: .right)
            let scale = parent.scale
            rowColumn.width = DatabaseTableMetrics.points(
                DatabaseTableMetrics.rowColumnWidth, scale: scale)
            rowColumn.minWidth = DatabaseTableMetrics.points(
                DatabaseTableMetrics.rowColumnMinimum, scale: scale)
            rowColumn.maxWidth = DatabaseTableMetrics.points(
                DatabaseTableMetrics.rowColumnMaximum, scale: scale)
            rowColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(rowColumn)

            fieldNames = parent.fields.map { $0.path.segments.joined(separator: ".") }
            for field in parent.fields {
                let name = field.path.segments.joined(separator: ".")
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
                column.title = field.displayName
                column.headerCell = makeHeaderCell(title: field.displayName)
                let scale = parent.scale
                let logical = parent.columnWidth(field.path) ?? initialWidth(for: field)
                column.width = logical * CGFloat(scale)
                column.minWidth = DatabaseTableMetrics.points(
                    DatabaseTableMetrics.columnMinimum, scale: scale)
                column.maxWidth = DatabaseTableMetrics.points(
                    DatabaseTableMetrics.columnMaximum, scale: scale)
                column.resizingMask = .userResizingMask
                if field.isSortable {
                    column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                }
                tableView.addTableColumn(column)
                columnsByName[name] = column
            }
            updateSortDescriptors()
            applyHeaderPalette()
        }

        func applyColumnWidths() {
            guard let tableView else { return }
            applyingColumnWidths = true
            defer { applyingColumnWidths = false }
            let scale = parent.scale
            if let row = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == Self.rowColumnIdentifier
            }) {
                row.minWidth = DatabaseTableMetrics.points(
                    DatabaseTableMetrics.rowColumnMinimum, scale: scale)
                row.maxWidth = DatabaseTableMetrics.points(
                    DatabaseTableMetrics.rowColumnMaximum, scale: scale)
            }
            for field in parent.fields {
                let name = field.path.segments.joined(separator: ".")
                guard let column = columnsByName[name] else { continue }
                column.minWidth = DatabaseTableMetrics.points(
                    DatabaseTableMetrics.columnMinimum, scale: scale)
                column.maxWidth = DatabaseTableMetrics.points(
                    DatabaseTableMetrics.columnMaximum, scale: scale)
                guard let width = parent.columnWidth(field.path) else { continue }
                let display = width * CGFloat(scale)
                guard abs(column.width - display) > 0.5 else { continue }
                column.width = display
            }
        }

        func consumeScaleChange(in scrollView: NSScrollView) -> CGPoint? {
            guard let tableView else { return nil }
            let scale = parent.scale
            let origin = scrollView.contentView.bounds.origin
            tableView.rowHeight = DatabaseTableMetrics.points(
                DatabaseTableMetrics.rowHeight, scale: scale)
            tableView.intercellSpacing = NSSize(
                width: DatabaseTableMetrics.points(
                    DatabaseTableMetrics.intercellWidth, scale: scale),
                height: 0)
            tableView.headerView?.frame.size.height = DatabaseTableMetrics.points(
                DatabaseTableMetrics.headerHeight, scale: scale)
            guard abs(scale - appliedScale) > 0.000_1 else { return nil }
            let ratio = appliedScale > 0 ? scale / appliedScale : 1
            appliedScale = scale
            let font = NSFont.systemFont(
                ofSize: DatabaseTableMetrics.points(DatabaseTableMetrics.headerFont, scale: scale),
                weight: .medium)
            for column in tableView.tableColumns {
                column.width *= ratio
                column.headerCell.font = font
            }
            tableView.headerView?.needsDisplay = true
            tableView.reloadData()
            return CGPoint(x: origin.x * ratio, y: origin.y * ratio)
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
            let textField = DatabaseNativeValueField(labelWithString: "")
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
            cell.font = .systemFont(
                ofSize: DatabaseTableMetrics.points(
                    DatabaseTableMetrics.headerFont, scale: parent.scale), weight: .medium)
            return cell
        }

        private func applyHeaderPalette() {
            guard let tableView else { return }
            for column in tableView.tableColumns {
                guard let cell = column.headerCell as? DatabaseNativeHeaderCell else { continue }
                cell.textColor = .secondaryLabelColor
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
            DatabaseGridProjection.preview(value)
        }

        private static let rowColumnIdentifier = "__database_row_number"
    }
}

struct DatabaseTablePaginationGate {
    private var requestedContinuation: DatabaseContinuationToken?

    mutating func shouldLoadMore(
        continuation: DatabaseContinuationToken?,
        isLoading: Bool,
        visibleMaxY: CGFloat,
        contentMaxY: CGFloat,
        rowHeight: CGFloat
    ) -> Bool {
        guard let continuation,
            !isLoading,
            continuation != requestedContinuation,
            visibleMaxY >= contentMaxY - max(rowHeight, 1) * 10
        else { return false }
        requestedContinuation = continuation
        return true
    }

    mutating func rearm() {
        requestedContinuation = nil
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
