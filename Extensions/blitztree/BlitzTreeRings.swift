import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct BlitzTreeRings: View {
    let report: BlitzTreeReport
    let activate: (BlitzTreeReport.Entry) -> Void
    @State private var selection: Double?
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.colorScheme) private var scheme

    private var entries: [BlitzTreeReport.Entry] {
        Array(report.report.inventory.largestChildren.filter { $0.allocatedBytes > 0 }.prefix(60))
    }

    var body: some View {
        let entries = entries
        let other = entries.reduce(report.summary.allocatedBytes) {
            $0 - min($0, $1.allocatedBytes)
        }
        let tones = BlitzTreePalette.tones(
            theme: AppTheme(storedName: themeName), dark: scheme == .dark)
        Chart {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                SectorMark(
                    angle: .value("Allocated bytes", Double(entry.allocatedBytes)),
                    innerRadius: .ratio(0.55), angularInset: 1
                )
                .foregroundStyle(Color(nsColor: tones[index % tones.count]))
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
                .foregroundStyle(.quaternary)
                .accessibilityLabel("Other unlisted space")
            }
        }
        .chartAngleSelection(value: $selection)
        .overlay {
            VStack(spacing: UIScale.pt(4)) {
                Text("Allocated").font(.edithText(.caption)).foregroundStyle(.secondary)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: report.summary.allocatedBytes),
                        countStyle: .file)
                )
                .font(.edithText(.title3)).fontWeight(.semibold)
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
