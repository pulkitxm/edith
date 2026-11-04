import AppKit
import SwiftUI

public struct VirtualList<Item: Identifiable & Equatable, Header: View, Row: View>:
    NSViewRepresentable
{
    let items: [Item]
    let rowHeight: (Item) -> CGFloat
    let header: Header
    let row: (Item) -> Row

    public init(
        _ items: [Item], rowHeight: @escaping (Item) -> CGFloat,
        @ViewBuilder header: () -> Header, @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self.rowHeight = rowHeight
        self.header = header()
        self.row = row
    }

    public func makeCoordinator() -> VirtualListCoordinator<Item> {
        VirtualListCoordinator()
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = VirtualListTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.allowsColumnResizing = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.onWidthChange = { [weak coordinator] in coordinator?.measureHeader() }
        let column = NSTableColumn(identifier: VirtualListCoordinator<Item>.column)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        coordinator.table = table
        update(coordinator, environment: context.environment)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(context.coordinator, environment: context.environment)
    }

    private func update(_ coordinator: VirtualListCoordinator<Item>, environment: EnvironmentValues)
    {
        coordinator.environment = environment
        coordinator.rowHeight = rowHeight
        coordinator.makeRow = { AnyView(row($0)) }
        coordinator.header = AnyView(header)
        coordinator.apply(items)
    }
}

@MainActor
public final class VirtualListCoordinator<Item: Identifiable & Equatable>: NSObject,
    NSTableViewDataSource, NSTableViewDelegate
{
    static var column: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("row") }
    static var headerCell: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("header")
    }
    static var itemCell: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("item") }

    weak var table: NSTableView?
    var environment = EnvironmentValues()
    var rowHeight: (Item) -> CGFloat = { _ in 44 }
    var makeRow: (Item) -> AnyView = { _ in AnyView(EmptyView()) }
    var header = AnyView(EmptyView())
    private(set) var items: [Item] = []
    private(set) var rowBuilds = 0
    private(set) var reloads = 0
    private var headerHeight: CGFloat = 0
    private lazy var headerProbe = NSHostingController(rootView: AnyView(EmptyView()))

    func apply(_ next: [Item]) {
        let previous = items
        items = next
        guard let table else { return }
        measureHeader()
        refresh(row: 0)
        guard previous.count != next.count || !previous.elementsEqual(next, by: { $0.id == $1.id })
        else {
            let changed = IndexSet(
                zip(previous, next).enumerated().compactMap { offset, pair in
                    pair.0 == pair.1 ? nil : offset + 1
                })
            guard !changed.isEmpty else { return }
            table.noteHeightOfRows(withIndexesChanged: changed)
            for row in changed { refresh(row: row) }
            return
        }
        reloads += 1
        table.reloadData()
    }

    func measureHeader() {
        guard let table else { return }
        headerProbe.rootView = content(for: 0)
        let width = max(1, table.bounds.width)
        let height = ceil(
            headerProbe.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                .height)
        guard abs(height - headerHeight) > 0.5 else { return }
        headerHeight = height
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
    }

    private func refresh(row: Int) {
        guard let table, row < table.numberOfRows,
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? VirtualListCell
        else { return }
        cell.host.rootView = content(for: row)
    }

    private func content(for row: Int) -> AnyView {
        let view = row == 0 ? header : makeRow(items[row - 1])
        return AnyView(view.environment(\.self, environment))
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { items.count + 1 }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row == 0 ? max(1, headerHeight) : max(1, rowHeight(items[row - 1]))
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = row == 0 ? Self.headerCell : Self.itemCell
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? VirtualListCell
            ?? VirtualListCell(identifier: identifier)
        if row > 0 { rowBuilds += 1 }
        cell.host.rootView = content(for: row)
        return cell
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        VirtualListRowView()
    }
}

final class VirtualListCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = []
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

final class VirtualListRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class VirtualListTableView: NSTableView {
    var onWidthChange: () -> Void = {}

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange() }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?)
        -> Bool
    {
        true
    }
}
