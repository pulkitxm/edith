import Charts
import EdithKit
import SwiftUI

struct BlitzTreeRings: View {
    let report: BlitzTreeReport
    let activate: (BlitzTreeReport.Entry) -> Void
    @State private var selection: Double?

    private var entries: [BlitzTreeReport.Entry] {
        Array(report.report.inventory.largestChildren.filter { $0.allocatedBytes > 0 }.prefix(60))
    }

    var body: some View {
        let entries = entries
        let other = entries.reduce(report.summary.allocatedBytes) {
            $0 - min($0, $1.allocatedBytes)
        }
        Chart {
            ForEach(entries) { entry in
                SectorMark(
                    angle: .value("Allocated bytes", Double(entry.allocatedBytes)),
                    innerRadius: .ratio(0.55), angularInset: 1
                )
                .foregroundStyle(by: .value("Folder", entry.name))
                .accessibilityLabel(entry.name)
                .accessibilityValue(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: entry.allocatedBytes), countStyle: .file))
            }
            if other > 0 {
                SectorMark(
                    angle: .value("Allocated bytes", Double(other)), innerRadius: .ratio(0.55),
                    angularInset: 1
                )
                .foregroundStyle(.gray.opacity(0.5))
                .accessibilityLabel("Other unlisted space")
            }
        }
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selection)
        .overlay {
            VStack(spacing: 4) {
                Text("Allocated").font(.caption).foregroundStyle(.secondary)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: report.summary.allocatedBytes),
                        countStyle: .file)
                )
                .font(.title3).fontWeight(.semibold)
            }
            .allowsHitTesting(false)
        }
        .onChange(of: selection) { _, value in
            guard let value else { return }
            var end = 0.0
            for entry in entries {
                end += Double(entry.allocatedBytes)
                if value < end { activate(entry); break }
            }
        }
    }
}
