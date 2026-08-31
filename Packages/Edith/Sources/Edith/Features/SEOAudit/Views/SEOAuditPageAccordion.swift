import EdithKit
import SwiftUI

struct SEOAuditPageAccordion: View {
    let page: SEOAuditPageResult
    let history: [SEOAuditPageResult]
    @Binding var expanded: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: UIScale.pt(12)) {
                    statusMark
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(
                            page.metadata.title ?? URL(string: page.url)?.lastPathComponent
                                ?? page.url
                        )
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                        Text(page.url)
                            .font(DashSkin.mono(9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: UIScale.pt(8))
                    if page.errorCount > 0 { issuePill(String(page.errorCount), .error) }
                    if page.warningCount > 0 { issuePill(String(page.warningCount), .warning) }
                    score
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, UIScale.pt(14))
                .frame(minHeight: UIScale.pt(58))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider().padding(.horizontal, UIScale.pt(14))
                detail
                    .padding(UIScale.pt(14))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
        )
        .animation(.easeOut(duration: 0.16), value: expanded)
    }

    private var statusMark: some View {
        ZStack {
            Circle().fill(statusColor.opacity(0.14))
            Image(systemName: page.error == nil ? "checkmark" : "xmark")
                .font(.system(size: UIScale.pt(9), weight: .bold))
                .foregroundStyle(statusColor)
        }
        .frame(width: UIScale.pt(25), height: UIScale.pt(25))
    }

    private var statusColor: Color {
        if page.error != nil || page.errorCount > 0 { return DashSkin.danger }
        if page.warningCount > 0 { return DashSkin.warn }
        return DashSkin.ok
    }

    private func issuePill(_ value: String, _ severity: SEOAuditSeverity) -> some View {
        HStack(spacing: UIScale.pt(3)) {
            Circle().fill(severityColor(severity)).frame(
                width: UIScale.pt(5), height: UIScale.pt(5))
            Text(value).font(DashSkin.mono(9.5, weight: .semibold))
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(4))
        .background(severityColor(severity).opacity(0.1), in: Capsule())
    }

    private var score: some View {
        Text(page.scores.average.map(String.init) ?? "—")
            .font(DashSkin.mono(11, weight: .semibold))
            .foregroundStyle(scoreColor(page.scores.average))
            .frame(width: UIScale.pt(28), alignment: .trailing)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: UIScale.pt(14)) {
                    openGraphPreview.frame(width: UIScale.pt(300))
                    auditFacts
                }
                VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                    openGraphPreview
                    auditFacts
                }
            }
            if !page.issues.isEmpty { issues }
            if !history.isEmpty { historyView }
        }
    }

    private var openGraphPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(DashSkin.line(dark).opacity(0.45))
                if let value = page.metadata.openGraphImageURL, let url = URL(string: value) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            previewFallback
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    previewFallback
                }
            }
            .aspectRatio(1.91, contentMode: .fit)
            .clipped()
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text(URL(string: page.url)?.host?.uppercased() ?? "PAGE")
                    .font(DashSkin.mono(8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text(page.metadata.openGraphTitle ?? page.metadata.title ?? "No social title")
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .lineLimit(1)
                Text(
                    page.metadata.openGraphDescription ?? page.metadata.description
                        ?? "No social description"
                )
                .font(.system(size: UIScale.pt(9.5)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .padding(UIScale.pt(10))
        }
        .background(DashSkin.paper(dark))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
    }

    private var previewFallback: some View {
        Image(systemName: "photo")
            .font(.system(size: UIScale.pt(24), weight: .light))
            .foregroundStyle(.tertiary)
    }

    private var auditFacts: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(8)) {
                scoreTile("PERF", page.scores.performance)
                scoreTile("A11Y", page.scores.accessibility)
                scoreTile("BEST", page.scores.bestPractices)
                scoreTile("SEO", page.scores.seo)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(120)), alignment: .leading)],
                alignment: .leading, spacing: UIScale.pt(10)
            ) {
                fact("Status", page.statusCode.map(String.init) ?? "Failed")
                fact("Response", page.responseMilliseconds.map { "\($0) ms" } ?? "—")
                fact(
                    "Size",
                    ByteCountFormatter.string(fromByteCount: Int64(page.bytes), countStyle: .file))
                fact("Words", String(page.metadata.wordCount))
                fact("Canonical", page.metadata.canonicalURL == nil ? "Missing" : "Present")
                fact("Robots", page.metadata.robots ?? "Default")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreTile(_ label: String, _ value: Int?) -> some View {
        VStack(spacing: UIScale.pt(3)) {
            Text(value.map(String.init) ?? "—")
                .font(DashSkin.mono(15, weight: .semibold))
                .foregroundStyle(scoreColor(value))
            Text(label).font(DashSkin.mono(7.5, weight: .bold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(label.uppercased()).font(DashSkin.mono(7.5, weight: .bold)).foregroundStyle(
                .tertiary)
            Text(value).font(.system(size: UIScale.pt(10.5), weight: .medium)).lineLimit(1)
        }
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            sectionLabel("Issues", count: page.issues.count)
            ForEach(page.issues) { issue in
                HStack(alignment: .top, spacing: UIScale.pt(8)) {
                    Circle().fill(severityColor(issue.severity))
                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                        .padding(.top, UIScale.pt(4))
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(issue.title).font(.system(size: UIScale.pt(11), weight: .semibold))
                        Text(issue.detail).font(.system(size: UIScale.pt(9.5))).foregroundStyle(
                            .secondary)
                    }
                }
            }
        }
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            sectionLabel("URL history", count: history.count)
            ForEach(history.prefix(5)) { previous in
                HStack(spacing: UIScale.pt(10)) {
                    Text(
                        previous.auditedAt,
                        format: .dateTime.month(.abbreviated).day().hour().minute()
                    )
                    .font(DashSkin.mono(9.5))
                    .frame(width: UIScale.pt(120), alignment: .leading)
                    Text("\(previous.issues.count) issues")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(previous.scores.average.map(String.init) ?? "—")
                        .font(DashSkin.mono(10.5, weight: .semibold))
                        .foregroundStyle(scoreColor(previous.scores.average))
                }
            }
        }
    }

    private func sectionLabel(_ value: String, count: Int) -> some View {
        HStack {
            Text(value).font(.system(size: UIScale.pt(11.5), weight: .semibold))
            Text(String(count)).font(DashSkin.mono(9)).foregroundStyle(.tertiary)
        }
    }

    private func severityColor(_ severity: SEOAuditSeverity) -> Color {
        switch severity {
        case .error: DashSkin.danger
        case .warning: DashSkin.warn
        case .notice: DashSkin.accent(dark)
        }
    }

    private func scoreColor(_ score: Int?) -> Color {
        guard let score else { return .secondary }
        if score >= 90 { return DashSkin.ok }
        if score >= 50 { return DashSkin.warn }
        return DashSkin.danger
    }
}
