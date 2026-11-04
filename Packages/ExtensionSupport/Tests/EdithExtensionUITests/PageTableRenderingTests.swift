import AppKit
import SwiftUI
import Testing
@testable import EdithExtensionUI

private struct SyntheticRow: Identifiable {
    let id: Int
    var name: String { "synthetic-package-\(id)" }
}

private struct SyntheticTable: View {
    let rows = (0..<40).map(SyntheticRow.init)

    var body: some View {
        Table(rows) {
            TableColumn("Name") { Text($0.name) }
                .width(min: UIScale.pt(PageMetrics.tableNameMinimumWidth), max: .infinity)
            TableColumn("Version") { _ in Text("1.0.0") }.width(UIScale.pt(120))
            TableColumn("Status") { _ in Text("Installed") }.width(UIScale.pt(80))
            TableColumn("Actions") { _ in Text("Remove") }.width(UIScale.pt(140))
        }
    }
}

extension SurfaceGridRenderingTests {
    @Test(arguments: [(640.0, 1.0), (900.0, 1.0), (900.0, 1.4)])
    func tableNameColumnFillsTheTableWithoutATrailingHeaderSegment(
        width: Double, zoom: Double
    ) async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        UIScale.apply(zoom)
        let host = NSHostingView(rootView: SyntheticTable())
        host.frame = NSRect(x: 0, y: 0, width: width, height: 360)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let table = try #require(Self.tableView(in: host))
        let leading = table.rect(ofColumn: 0).minX
        let trailing = table.bounds.width - table.rect(ofColumn: table.numberOfColumns - 1).maxX
        #expect(abs(trailing - leading) <= 1, "leading \(leading) trailing \(trailing)")
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = tableView(in: subview) { return table }
        }
        return nil
    }
}
