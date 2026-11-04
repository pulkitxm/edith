import AppKit
import SwiftUI
import Testing

@testable import EdithExtensionUI

@Suite(.serialized) @MainActor struct PageScrollPerformanceTests {
    static let benchmark = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: benchmark)) func longPagesScrollWithinTheFrameBudget() async {
        for (name, view) in [
            ("scaffold", AnyView(SyntheticRows.scaffold(loading: false))),
            ("scaffold+loading", AnyView(SyntheticRows.scaffold(loading: true))),
            ("virtual-list", AnyView(SyntheticRows.virtual)),
        ] {
            let (window, host) = ScrollFrameHarness.host(
                view.environment(\.colorScheme, .dark), size: CGSize(width: 1200, height: 860))
            await ScrollFrameHarness.settle(host, for: .seconds(1))
            let timing = await ScrollFrameHarness.scroll(host, frames: 400)
            print("page-scroll \(name): \(timing)")
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}

enum SyntheticRows {
    static let rows = (0..<3_000).map { index in
        SyntheticRow(
            id: index, title: "Synthetic item \(index)",
            detail: "Detail line for item \(index) with some extra words",
            value: "\(index % 97)m")
    }

    @MainActor @ViewBuilder
    static func scaffold(loading: Bool) -> some View {
        PageScaffold(pinnedHeader: true) {
            PageHeader("Synthetic")
        } content: {
            if loading {
                PageLoading(state: .content) { list }
            } else {
                list
            }
        }
    }

    @MainActor static var virtual: some View {
        VirtualList(rows, rowHeight: { _ in 46 }) {
            PageHeader("Synthetic")
        } row: { row in
            SyntheticRowView(row: row).padding(.horizontal, 24)
        }
    }

    @MainActor static var list: some View {
        ForEach(rows) { row in
            SyntheticRowView(row: row)
        }
    }
}

struct SyntheticRow: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
    let value: String
}

struct SyntheticRowView: View {
    let row: SyntheticRow

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(.teal.opacity(0.4)).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(row.value).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .padding(.vertical, 6)
    }
}
