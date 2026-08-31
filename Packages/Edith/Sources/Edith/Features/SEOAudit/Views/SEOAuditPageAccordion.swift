import AppKit
import EdithKit
import SwiftUI

struct SEOAuditPageAccordion: View {
    let page: SEOAuditPageResult
    let history: [SEOAuditPageResult]
    @Binding var selected: Bool
    let lighthouseAvailable: Bool
    let lighthouseRunning: Bool
    let runLighthouse: () -> Void
    let socialPlatform: SEOAuditSocialPlatform
    @Binding var expanded: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(10)) {
                Toggle("Select \(page.url)", isOn: $selected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .padding(.leading, UIScale.pt(14))
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
                            .animation(.easeOut(duration: 0.16), value: expanded)
                    }
                    .padding(.trailing, UIScale.pt(14))
                    .frame(minHeight: UIScale.pt(58))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
            }
            if expanded {
                Divider().padding(.horizontal, UIScale.pt(14))
                detail
                    .padding(UIScale.pt(14))
            }
        }
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1))
        )
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
            HStack(spacing: UIScale.pt(10)) {
                if let url = URL(string: page.url) {
                    Link(destination: url) {
                        Label("Open page", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                }
                Button(action: runLighthouse) {
                    Label(
                        page.hasLighthouseScores ? "Run Lighthouse again" : "Run Lighthouse",
                        systemImage: "gauge.with.needle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!lighthouseAvailable || lighthouseRunning)
                if lighthouseRunning {
                    ProgressView().controlSize(.small)
                    Text("Running four Lighthouse categories")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                } else if !lighthouseAvailable {
                    Text("Install the Lighthouse CLI to enable page scores.")
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .foregroundStyle(DashSkin.warn)
                }
                Spacer()
                Text(selected ? "Included in next audit" : "Excluded from next audit")
                    .font(DashSkin.mono(9, weight: .semibold))
                    .foregroundStyle(selected ? DashSkin.ok : .secondary)
            }
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
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            HStack(spacing: UIScale.pt(6)) {
                Label(socialPlatform.title, systemImage: socialPlatform.icon)
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                Spacer(minLength: UIScale.pt(8))
                Text(previewFormatLabel)
                    .font(DashSkin.mono(8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            platformPreview
        }
    }

    @ViewBuilder
    private var platformPreview: some View {
        switch socialPlatform {
        case .facebook:
            facebookPreview
        case .x:
            xPreview
        case .linkedIn:
            linkedInPreview
        case .slack:
            slackPreview
        case .discord:
            discordPreview
        }
    }

    private var facebookPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewImage.aspectRatio(1200 / 630, contentMode: .fit)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                previewDomain
                previewTitle.lineLimit(1)
                previewDescription.lineLimit(2)
            }
            .padding(UIScale.pt(10))
        }
        .socialPreviewSurface(dark: dark)
    }

    @ViewBuilder
    private var xPreview: some View {
        if usesXSummaryCard {
            HStack(spacing: 0) {
                previewImage
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: UIScale.pt(104), height: UIScale.pt(104))
                    .clipped()
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    previewTitle.lineLimit(2)
                    previewDescription.lineLimit(2)
                    previewDomain
                }
                .padding(UIScale.pt(10))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .socialPreviewSurface(dark: dark)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                previewImage.aspectRatio(2, contentMode: .fit)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    previewTitle.lineLimit(2)
                    previewDescription.lineLimit(2)
                    previewDomain
                }
                .padding(UIScale.pt(10))
            }
            .socialPreviewSurface(dark: dark)
        }
    }

    private var linkedInPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewImage.aspectRatio(1200 / 627, contentMode: .fit)
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                previewTitle.lineLimit(2)
                previewDomain
            }
            .padding(UIScale.pt(10))
        }
        .socialPreviewSurface(dark: dark)
    }

    private var slackPreview: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            previewDomain
            previewTitle.lineLimit(2)
            previewDescription.lineLimit(3)
            previewImage
                .aspectRatio(1200 / 630, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(7)))
        }
        .padding(UIScale.pt(10))
        .padding(.leading, UIScale.pt(4))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: UIScale.pt(2))
                .fill(DashSkin.accent(dark))
                .frame(width: UIScale.pt(3))
                .padding(.vertical, UIScale.pt(7))
        }
    }

    private var discordPreview: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            previewDomain
            previewTitle.lineLimit(2)
            previewDescription.lineLimit(3)
            previewImage
                .aspectRatio(1200 / 630, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(7)))
        }
        .padding(UIScale.pt(11))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(9))
                .strokeBorder(DashSkin.accent(dark).opacity(0.32), lineWidth: UIScale.pt(1)))
    }

    private var previewImage: some View {
        ZStack {
            Rectangle().fill(DashSkin.line(dark).opacity(0.45))
            if let previewSnapshotImage {
                Image(nsImage: previewSnapshotImage).resizable().scaledToFill()
            } else if let previewImageURL {
                AsyncImage(url: previewImageURL) { phase in
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
        .clipped()
    }

    private var previewTitle: some View {
        Text(
            socialPlatform == .x
                ? page.metadata.twitterTitle ?? page.metadata.openGraphTitle
                    ?? page.metadata.title ?? "No social title"
                : page.metadata.openGraphTitle ?? page.metadata.title ?? "No social title"
        )
        .font(.system(size: UIScale.pt(11.5), weight: .semibold))
    }

    private var previewDescription: some View {
        Text(
            socialPlatform == .x
                ? page.metadata.twitterDescription ?? page.metadata.openGraphDescription
                    ?? page.metadata.description ?? "No social description"
                : page.metadata.openGraphDescription ?? page.metadata.description
                    ?? "No social description"
        )
        .font(.system(size: UIScale.pt(9.5)))
        .foregroundStyle(.secondary)
    }

    private var previewDomain: some View {
        Text(URL(string: page.url)?.host?.uppercased() ?? "PAGE")
            .font(DashSkin.mono(8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    private var previewImageURL: URL? {
        let value =
            socialPlatform == .x
            ? page.metadata.twitterImageURL ?? page.metadata.openGraphImageURL
            : page.metadata.openGraphImageURL
        return value.flatMap(URL.init(string:))
    }

    private var previewSnapshotImage: NSImage? {
        let value =
            socialPlatform == .x
            ? page.metadata.twitterImageSnapshotURL
                ?? page.metadata.openGraphImageSnapshotURL
            : page.metadata.openGraphImageSnapshotURL
        guard let value, let url = URL(string: value), url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var usesXSummaryCard: Bool {
        page.metadata.twitterCard?.lowercased() == "summary"
    }

    private var previewFormatLabel: String {
        usesXSummaryCard && socialPlatform == .x ? "1:1 · summary" : socialPlatform.formatLabel
    }

    private var previewFallback: some View {
        Image(systemName: "photo")
            .font(.system(size: UIScale.pt(24), weight: .light))
            .foregroundStyle(.tertiary)
    }

    private var auditFacts: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                HStack {
                    sectionLabel("Lighthouse", count: page.scores.values.count)
                    Spacer()
                    Text(page.hasLighthouseScores ? "latest local run" : "not run")
                        .font(DashSkin.mono(8.5, weight: .semibold))
                        .foregroundStyle(page.hasLighthouseScores ? DashSkin.ok : .secondary)
                }
                if page.hasLighthouseScores {
                    HStack(spacing: UIScale.pt(8)) {
                        scoreTile("PERF", page.scores.performance)
                        scoreTile("A11Y", page.scores.accessibility)
                        scoreTile("BEST", page.scores.bestPractices)
                        scoreTile("SEO", page.scores.seo)
                    }
                } else {
                    HStack(spacing: UIScale.pt(9)) {
                        Image(systemName: "gauge.open.with.lines.needle.33percent")
                            .foregroundStyle(DashSkin.accent(dark))
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text("No Lighthouse report for this page")
                                .font(.system(size: UIScale.pt(11), weight: .semibold))
                            Text(
                                lighthouseAvailable
                                    ? "Run it here, or include Lighthouse in the next bulk audit."
                                    : "Install the Lighthouse CLI, then return to this page."
                            )
                            .font(.system(size: UIScale.pt(9.5)))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(UIScale.pt(11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        DashSkin.accent(dark).opacity(0.07),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
                }
            }
            .padding(UIScale.pt(12))
            .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
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
            .padding(UIScale.pt(12))
            .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            metadataPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            sectionLabel("Search and social", count: metadataValues.count)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(170)), alignment: .leading)],
                alignment: .leading, spacing: UIScale.pt(9)
            ) {
                ForEach(metadataValues, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(label.uppercased())
                            .font(DashSkin.mono(7.5, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(value)
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(
                                value == "Missing" ? DashSkin.warn : DashSkin.ink(dark)
                            )
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(UIScale.pt(12))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
    }

    private var metadataValues: [(String, String)] {
        [
            ("Title", page.metadata.title ?? "Missing"),
            ("Description", page.metadata.description ?? "Missing"),
            ("H1", page.metadata.heading ?? "Missing"),
            ("Language", page.metadata.language ?? "Missing"),
            ("OG type", page.metadata.openGraphType ?? "Missing"),
            ("Twitter card", page.metadata.twitterCard ?? "Missing"),
        ]
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

private extension View {
    func socialPreviewSurface(dark: Bool) -> some View {
        background(DashSkin.paper(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1)))
    }
}
