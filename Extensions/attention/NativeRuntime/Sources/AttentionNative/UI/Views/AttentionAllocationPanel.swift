@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import Charts
import SwiftUI

struct AttentionAllocationPanel: View {
    let model: AttentionPageModel
    @State private var selectedAngle: Double?
    @Environment(\.colorScheme) private var scheme

    private var levels: [AttentionProductivity] {
        AttentionPalette.levels.filter { model.summary.duration($0) > 0 }
    }

    private var hoveredLevel: AttentionProductivity? {
        guard let selectedAngle else { return nil }
        var accumulated = 0.0
        return levels.first { level in
            accumulated += model.summary.duration(level)
            return selectedAngle < accumulated
        }
    }

    var body: some View {
        AttentionPanel(
            "Time allocation",
            subtitle: "Active time, with productivity and work or personal context kept separate."
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: UIScale.pt(32)) {
                    allocation.frame(minWidth: UIScale.pt(460), maxWidth: .infinity)
                    Divider().frame(height: UIScale.pt(180))
                    context.frame(minWidth: UIScale.pt(280), maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 20) {
                    allocation
                    context
                }
            }
        }
    }

    private var allocation: some View {
        let dark = scheme == .dark
        return HStack(spacing: UIScale.pt(22)) {
            Chart(levels, id: \.self) { level in
                SectorMark(
                    angle: .value("Active time", model.summary.duration(level)),
                    innerRadius: .ratio(0.74), angularInset: 2
                )
                .foregroundStyle(AttentionPalette.level(level, dark: dark))
                .opacity(hoveredLevel == nil || hoveredLevel == level ? 1 : 0.35)
                .cornerRadius(3)
                .accessibilityLabel(level.title)
                .accessibilityValue(AttentionFormat.duration(model.summary.duration(level)))
            }
            .chartLegend(.hidden)
            .chartAngleSelection(value: $selectedAngle)
            .chartBackground { _ in
                VStack(spacing: 4) {
                    Text(
                        AttentionFormat.duration(
                            hoveredLevel.map { model.summary.duration($0) }
                                ?? model.summary.activeDuration)
                    )
                    .font(DashSkin.heading(20)).monospacedDigit()
                    Text(hoveredLevel?.title.uppercased() ?? "ACTIVE TIME")
                        .font(DashSkin.mono(9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: UIScale.pt(170), height: UIScale.pt(170))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(levels, id: \.self) { level in
                    Button {
                        model.toggle(level: level)
                        model.section = .breakdown
                    } label: {
                        AttentionLegendRow(
                            color: AttentionPalette.level(level, dark: dark), label: level.title,
                            value: AttentionFormat.duration(model.summary.duration(level)),
                            detail: AttentionFormat.percent(
                                model.summary.duration(level), of: model.summary.activeDuration))
                    }
                    .buttonStyle(.edith(.borderless))
                    .help("Explore \(level.title.lowercased()) activity")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var context: some View {
        let dark = scheme == .dark
        let summary = model.summary
        return VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("WORK AND PERSONAL").font(DashSkin.mono(10)).foregroundStyle(.secondary)
            ForEach(AttentionSphere.allCases, id: \.self) { sphere in
                let duration = summary.duration(sphere)
                if duration > 0 {
                    Button {
                        model.toggle(sphere: sphere)
                        model.section = .breakdown
                    } label: {
                        AttentionLabeledBar(
                            title: sphere == .both ? "Shared context" : sphere.title,
                            duration: duration, total: summary.activeDuration,
                            color: sphere == .work ? DashSkin.accent(dark) : .secondary)
                    }
                    .buttonStyle(.edith(.borderless))
                    .help("Explore \(sphere.title.lowercased()) activity")
                }
            }
            if summary.unclassifiedDuration > 0 {
                Button {
                    model.filter(category: AttentionCatalog.unclassified)
                } label: {
                    Label(
                        "\(AttentionFormat.duration(summary.unclassifiedDuration)) needs categorization",
                        systemImage: "tag"
                    )
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                }
                .buttonStyle(.edith(.borderless))
                Text("Included in neutral time until you choose a category.")
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            }
        }
    }
}
