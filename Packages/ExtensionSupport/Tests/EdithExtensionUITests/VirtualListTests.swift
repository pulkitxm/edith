import AppKit
import Observation
import SwiftUI
import Testing

@testable import EdithExtensionUI

@Suite(.serialized) @MainActor struct VirtualListTests {
    @Test func scrollingThousandsOfRowsReusesAHandfulOfCells() async throws {
        let (window, host) = ScrollFrameHarness.host(
            list(ScrollFixtureRows.rows), size: CGSize(width: 900, height: 700))
        defer { window.orderOut(nil) }
        await ScrollFrameHarness.settle(host)
        let scroll = try #require(ScrollFrameHarness.scrollView(in: host))
        let table = try #require(scroll.documentView as? NSTableView)
        let coordinator = try #require(table.delegate as? VirtualListCoordinator<ScrollFixtureRow>)
        #expect(table.numberOfRows == ScrollFixtureRows.rows.count + 1)
        let reloads = coordinator.reloads
        _ = await ScrollFrameHarness.scroll(host, step: 400, frames: 120)
        let visible = table.rows(in: table.visibleRect).length
        #expect(visible > 5)
        #expect(table.subviews.count <= visible + 8)
        #expect(coordinator.rowBuilds < ScrollFixtureRows.rows.count)
        #expect(coordinator.reloads == reloads)
    }

    @Test func updatingOneItemRefreshesOnlyThatRow() async throws {
        var rows = Array(ScrollFixtureRows.rows.prefix(200))
        let model = VirtualListModel(rows: rows)
        let (window, host) = ScrollFrameHarness.host(
            VirtualListHarnessView(model: model), size: CGSize(width: 900, height: 700))
        defer { window.orderOut(nil) }
        await ScrollFrameHarness.settle(host)
        let scroll = try #require(ScrollFrameHarness.scrollView(in: host))
        let table = try #require(scroll.documentView as? NSTableView)
        let coordinator = try #require(table.delegate as? VirtualListCoordinator<ScrollFixtureRow>)
        let builds = coordinator.rowBuilds
        let reloads = coordinator.reloads
        rows[3] = ScrollFixtureRow(id: 3, title: "Renamed", detail: "Changed", value: "1m")
        model.rows = rows
        await ScrollFrameHarness.settle(host)
        #expect(coordinator.reloads == reloads)
        #expect(coordinator.rowBuilds == builds)
        #expect(coordinator.items[3].title == "Renamed")
        model.rows = Array(rows.reversed())
        await ScrollFrameHarness.settle(host)
        #expect(coordinator.reloads == reloads + 1)
        #expect(coordinator.items.first?.id == 199)
    }

    @Test func theHeaderRowFollowsItsContentHeight() async throws {
        let model = VirtualListModel(rows: Array(ScrollFixtureRows.rows.prefix(20)))
        let (window, host) = ScrollFrameHarness.host(
            VirtualListHarnessView(model: model), size: CGSize(width: 900, height: 700))
        defer { window.orderOut(nil) }
        await ScrollFrameHarness.settle(host)
        let table = try #require(
            ScrollFrameHarness.scrollView(in: host)?.documentView as? NSTableView)
        let short = table.rect(ofRow: 0).height
        model.headerLines = 6
        await ScrollFrameHarness.settle(host)
        #expect(table.rect(ofRow: 0).height > short + 40)
    }

    @Test func aFlexibleHeaderIsMeasuredAtItsIdealHeight() async throws {
        let view = VirtualList(Array(ScrollFixtureRows.rows.prefix(50)), rowHeight: { _ in 46 }) {
            VStack {
                Text("Header")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } row: { row in
            ScrollFixtureRowView(row: row)
        }
        let (window, host) = ScrollFrameHarness.host(view, size: CGSize(width: 900, height: 700))
        defer { window.orderOut(nil) }
        await ScrollFrameHarness.settle(host)
        let table = try #require(
            ScrollFrameHarness.scrollView(in: host)?.documentView as? NSTableView)
        let header = table.rect(ofRow: 0).height
        #expect(header.isFinite)
        #expect(header < 200)
    }

    private func list(_ rows: [ScrollFixtureRow]) -> some View {
        VirtualList(rows, rowHeight: { _ in 46 }) {
            Text("Header")
        } row: { row in
            ScrollFixtureRowView(row: row)
        }
    }
}

@Suite @MainActor struct ContentLoadObservationTests {
    @Test func refreshingRetainedContentDoesNotNotifyStateObservers() {
        let load = ContentLoad()
        load.setContent()
        var notified = false
        withObservationTracking {
            _ = load.state
            _ = load.hasContent
            _ = load.errorMessage
        } onChange: {
            notified = true
        }
        let request = load.begin()
        load.complete(request)
        #expect(!notified)
        #expect(load.state == .content)
    }
}

@MainActor @Observable
final class VirtualListModel {
    var rows: [ScrollFixtureRow]
    var headerLines = 1

    init(rows: [ScrollFixtureRow]) { self.rows = rows }
}

struct VirtualListHarnessView: View {
    let model: VirtualListModel

    var body: some View {
        VirtualList(model.rows, rowHeight: { _ in 46 }) {
            VStack(alignment: .leading) {
                ForEach(0..<model.headerLines, id: \.self) { line in
                    Text("Header line \(line)").font(.title2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } row: { row in
            ScrollFixtureRowView(row: row)
        }
    }
}
