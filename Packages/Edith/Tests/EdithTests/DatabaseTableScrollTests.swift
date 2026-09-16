import AppKit
import EdithDatabase
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized)
struct DatabaseTableScrollTests {
    @Test func nativeTableRestoresBothScrollAxesAfterRecreation() throws {
        _ = TestWindowHost.application
        var savedOffset = CGPoint.zero
        let fields = (0..<6).map { index in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath("column\(index)"),
                displayName: "column\(index)", typeName: "text", isNullable: false,
                isSortable: true, isFilterable: true)
        }
        let records = (0..<100).map { index in
            DatabaseRecord(
                fields: fields.map {
                    DatabaseObjectField(name: $0.displayName, value: .string("sample \(index)"))
                })
        }
        func view(_ offset: CGPoint) -> DatabaseNativeTableView {
            DatabaseNativeTableView(
                accent: .orange, background: .black, grid: .gray,
                ink: .white, inkFaint: .gray, fields: fields, records: records,
                selectedIndex: nil, sorts: [], nextContinuation: nil, isLoading: false,
                columnWidth: { _ in 180 }, text: { "\($0)" }, loadMore: {}, select: { _ in },
                open: { _ in }, rowIsEditable: { _ in false }, canEdit: { _, _ in false },
                edit: { _, _, _ in }, sort: { _, _ in }, resizeColumn: { _, _ in },
                scrollOffset: offset, saveScrollOffset: { savedOffset = $0 })
        }
        func host(_ offset: CGPoint) -> NSWindow {
            let host = NSHostingView(rootView: view(offset))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            return window
        }
        let first = host(.zero)
        let scroll = try #require(findScroll(first.contentView))
        scroll.contentView.scroll(to: CGPoint(x: 150, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(savedOffset.x == 150)
        #expect(savedOffset.y == 600)
        let expected = savedOffset
        first.orderOut(nil)
        first.contentView = nil
        let second = host(expected)
        defer { second.orderOut(nil) }
        let restored = try #require(findScroll(second.contentView))
        #expect(restored.contentView.bounds.origin == expected)
    }

    private func findScroll(_ view: NSView?) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView { return scroll }
        for child in view?.subviews ?? [] {
            if let found = findScroll(child) { return found }
        }
        return nil
    }
}
