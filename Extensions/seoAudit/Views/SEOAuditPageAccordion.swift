import AppKit
import EdithExtensionSupport
import EdithExtensionUI
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
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @State private var imageFinished = false
    @State private var snapshotImage: NSImage?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: UIScale.pt(10)) {
                Toggle("Select \(page.url)", isOn: $selected)
                    .toggleStyle(.edithCheckboxMark)
                    .accessibilityLabel("Select \(page.url)")
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
                            .font(.edithText(.callout).weight(.semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                            Text(page.url)
                                .font(.edithText(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: UIScale.pt(8))
                        if page.errorCount > 0 { issuePill(String(page.errorCount), .error) }
                        if page.warningCount > 0 { issuePill(String(page.warningCount), .warning) }
                        score
                        Image(systemName: "chevron.right")
                            .font(.edithText(.caption).weight(.semibold))
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
                .font(.edithText(.caption).weight(.bold))
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
            Text(value).font(.edithText(.caption).weight(.semibold))
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(4))
        .background(severityColor(severity).opacity(0.1), in: Capsule())
    }

    private var score: some View {
        Text(page.scores.average.map(String.init) ?? "-")
            .font(DashSkin.mono(11, weight: .semibold))
            .foregroundStyle(scoreColor(page.scores.average))
            .frame(width: UIScale.pt(28), alignment: .trailing)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            WrapHStack(spacing: UIScale.pt(10)) {
                if let url = URL(string: page.url) {
                    Link(destination: url) {
                        Label("Open page", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.edith(.secondary))
                }
                Button(action: runLighthouse) {
                    Label(
                        page.hasLighthouseScores ? "Run Lighthouse again" : "Run Lighthouse",
                        systemImage: "gauge.with.needle")
                }
                .buttonStyle(.edith(.secondary))
                .disabled(!lighthouseAvailable || lighthouseRunning)
                if lighthouseRunning {
                    SkeletonGroup {
                        SkeletonBlock(width: 176, height: 9)
                    }
                    .accessibilityLabel("Running four Lighthouse categories")
                } else if !lighthouseAvailable {
                    Text("Install the Lighthouse CLI to enable page scores.")
                        .font(.edithText(.caption).weight(.medium))
                        .foregroundStyle(DashSkin.warn)
                }
                Text(selected ? "Included in next audit" : "Excluded from next audit")
                    .font(.edithText(.caption).weight(.semibold))
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
                    .font(.edithText(.caption).weight(.semibold))
                Spacer(minLength: UIScale.pt(8))
                Text(previewFormatLabel)
                    .font(.edithText(.caption).weight(.semibold))
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
            if let snapshotImage {
                Image(nsImage: snapshotImage).resizable().scaledToFill()
            } else if !imageFinished, snapshotFileURL != nil || previewImageURL != nil {
                SEOAuditImageSkeleton()
            } else {
                previewFallback
            }
        }
        .clipped()
        .pageTask(id: snapshotFileURL ?? previewImageURL) {
            snapshotImage = nil; imageFinished = false
            guard !SEOAuditPrivacyState.shared.hidden,
                let url = snapshotFileURL ?? (automaticActionsEnabled ? previewImageURL : nil)
            else { imageFinished = true; return }
            let loaded = await SEOSnapshotCache.image(for: url)
            guard !Task.isCancelled, !SEOAuditPrivacyState.shared.hidden else { return }
            snapshotImage = loaded; imageFinished = true
        }
    }

    private var socialCard: SEOAuditSocialCard {
        SEOAuditSocialCard(metadata: page.metadata, platform: socialPlatform)
    }

    private var previewTitle: some View {
        Text(socialCard.title)
            .font(.edithText(.subheadline).weight(.semibold))
    }

    private var previewDescription: some View {
        Text(socialCard.detail)
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
    }

    private var previewDomain: some View {
        PageCapsLabel(URL(string: page.url)?.host ?? "Page")
    }

    private var previewImageURL: URL? {
        socialCard.imageURL.flatMap(URL.init(string:))
    }

    private var snapshotFileURL: URL? {
        let value =
            socialPlatform == .x
            ? page.metadata.twitterImageSnapshotURL
                ?? page.metadata.openGraphImageSnapshotURL
            : page.metadata.openGraphImageSnapshotURL
        guard let value, let url = URL(string: value), url.isFileURL else { return nil }
        return url
    }

    private var usesXSummaryCard: Bool { socialCard.usesSummaryCard }

    private var previewFormatLabel: String { socialCard.formatLabel }

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
                        .font(.edithText(.caption).weight(.semibold))
                        .foregroundStyle(page.hasLighthouseScores ? DashSkin.ok : .secondary)
                }
                if lighthouseRunning {
                    SEOAuditScoreTilesSkeleton(dark: dark)
                } else if page.hasLighthouseScores {
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
                                .font(.edithText(.subheadline).weight(.semibold))
                            Text(
                                lighthouseAvailable
                                    ? "Run it here, or include Lighthouse in the next bulk audit."
                                    : "Install the Lighthouse CLI, then return to this page."
                            )
                            .font(.edithText(.caption))
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
            PageMetricGrid(minimumWidth: 120) {
                fact("Status", page.statusCode.map(String.init) ?? "Failed")
                fact("Response", page.responseMilliseconds.map { "\($0) ms" } ?? "-")
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
            PageMetricGrid(minimumWidth: 170) {
                ForEach(metadataValues, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        PageCapsLabel(label)
                        Text(value)
                            .font(.edithText(.caption))
                            .foregroundStyle(
                                value == "Missing" ? DashSkin.warn : DashSkin.ink(dark)
                            )
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(value.map(String.init) ?? "-")
                .font(DashSkin.mono(15, weight: .semibold))
                .foregroundStyle(scoreColor(value))
            Text(label).font(.edithText(.caption).weight(.bold)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(8))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            PageCapsLabel(label)
            Text(value).font(.edithText(.caption).weight(.medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(issue.title).font(.edithText(.subheadline).weight(.semibold))
                        Text(issue.detail).font(.edithText(.caption)).foregroundStyle(
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
                    .font(.edithText(.caption))
                    .frame(width: UIScale.pt(120), alignment: .leading)
                    Text("\(previous.issues.count) issues")
                        .font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(previous.scores.average.map(String.init) ?? "-")
                        .font(DashSkin.mono(10.5, weight: .semibold))
                        .foregroundStyle(scoreColor(previous.scores.average))
                }
            }
        }
    }

    private func sectionLabel(_ value: String, count: Int) -> some View {
        HStack {
            Text(value).font(.edithText(.subheadline).weight(.semibold))
            Text(String(count)).font(.edithText(.caption)).foregroundStyle(.tertiary)
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
