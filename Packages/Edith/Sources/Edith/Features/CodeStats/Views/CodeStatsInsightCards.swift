import EdithKit
import SwiftUI

struct CodeStatsAuditCard: View {
    let audit: CodeStatsAudit
    let model: CodeStatsModel
    let dark: Bool

    var body: some View {
        SkinCard(title: "What counts", note: "Counted versus excluded, with the reason", dark: dark)
        {
            HStack(spacing: UIScale.pt(18)) {
                tally("Counted", audit.counted, emphasis: true)
                tally("Raw in the mirror", audit.raw, emphasis: false)
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text("BULK THRESHOLD")
                        .font(DashSkin.mono(9))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Text(CodeStatsNumberFormat.compact(audit.bulkThreshold) + " lines per commit")
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                }
            }
            Divider()
            VStack(spacing: UIScale.pt(6)) {
                ForEach(audit.entries, id: \.reason) { entry in
                    if (entry.commits ?? 0) > 0 || (entry.lines ?? 0) > 0 {
                        row(entry)
                    }
                }
            }
        }
    }

    private func tally(_ title: String, _ value: CodeStatsTally, emphasis: Bool) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(title.uppercased())
                .font(DashSkin.mono(9))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(CodeStatsNumberFormat.compact(value.lines) + " lines")
                .font(.system(size: UIScale.pt(emphasis ? 18 : 14), weight: .semibold))
                .foregroundStyle(emphasis ? DashSkin.ink(dark) : DashSkin.inkSoft(dark))
            Text(CodeStatsNumberFormat.grouped(value.commits) + " commits")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .monospacedDigit()
    }

    private func row(_ entry: CodeStatsAuditEntry) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: entry.counted ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(entry.counted ? DashSkin.ok : DashSkin.inkFaint(dark))
            Text(entry.reason.title)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer()
            Text(detail(entry))
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .monospacedDigit()
            if let toggle = toggle(for: entry.reason) {
                Button(entry.counted ? "Exclude" : "Count") {
                    Task { await model.updateFilter(toggle) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: UIScale.pt(11), weight: .medium))
            }
        }
    }

    private func detail(_ entry: CodeStatsAuditEntry) -> String {
        [
            entry.commits.map { CodeStatsNumberFormat.grouped($0) + " commits" },
            entry.lines.map { CodeStatsNumberFormat.compact($0) + " lines" },
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private func toggle(for reason: CodeStatsAuditReason) -> ((inout CodeStatsFilter) -> Void)? {
        switch reason {
        case .bulk: { $0.includeBulk.toggle() }
        case .formatting: { $0.includeFormatting.toggle() }
        case .agentAssisted: { $0.includeAgentAssisted.toggle() }
        case .coAuthored: { $0.includeCoAuthored.toggle() }
        case .data: { $0.categories.formSymmetricDifference([.data]) }
        case .markup: { $0.categories.formSymmetricDifference([.markup]) }
        case .docs: { $0.categories.formSymmetricDifference([.docs]) }
        default: nil
        }
    }
}

struct CodeStatsLargestCommitsCard: View {
    let commits: [CodeStatsFactCommit]
    let dark: Bool
    @Environment(\.codeStatsActions) private var actions

    private static let shown = 12

    var body: some View {
        SkinCard(
            title: "Biggest commits", note: "Raw size, with how each one is counted", dark: dark
        ) {
            VStack(spacing: UIScale.pt(7)) {
                ForEach(commits.prefix(Self.shown), id: \.sha) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
                        Text(CodeStatsNumberFormat.compact(commit.raw))
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .frame(width: UIScale.pt(56), alignment: .trailing)
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(commit.subject)
                                .font(.system(size: UIScale.pt(12), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(1)
                            HStack(spacing: UIScale.pt(6)) {
                                Button(commit.repository) {
                                    actions.toggleRepository(commit.repository)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DashSkin.accent(dark))
                                Text(commit.day)
                                Text(String(commit.sha.prefix(8))).font(DashSkin.mono(10))
                                Text(
                                    CodeStatsNumberFormat.compact(commit.lines) + " counted, "
                                        + CodeStatsNumberFormat.grouped(commit.files) + " files")
                            }
                            .font(.system(size: UIScale.pt(10.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                        Spacer()
                        ForEach(CodeStatsCommitBadge.badges(commit.flags), id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: UIScale.pt(10), weight: .semibold))
                                .padding(.horizontal, UIScale.pt(6))
                                .padding(.vertical, UIScale.pt(2))
                                .background(DashSkin.paper2(dark), in: Capsule())
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                    }
                }
                if commits.isEmpty {
                    Text("No commits in the mirror yet.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
        }
    }
}

enum CodeStatsCommitBadge {
    static func badges(_ flags: CodeStatsCommitFlags) -> [String] {
        var badges: [String] = []
        if flags.contains(.bulk) { badges.append("Bulk") }
        if flags.contains(.formatting) { badges.append("Formatting") }
        if flags.contains(.agentAssisted) { badges.append("Agent") }
        if flags.contains(.coAuthored) { badges.append("Co-author") }
        return badges
    }
}

struct CodeStatsHygieneCard: View {
    let audit: CodeStatsAudit
    let model: CodeStatsModel
    let dark: Bool

    var body: some View {
        if !audit.duplicateRepositories.isEmpty || !audit.suggestions.isEmpty {
            SkinCard(
                title: "Duplicates and identities", note: "Counted once, never twice", dark: dark
            ) {
                if !audit.suggestions.isEmpty {
                    Text("These authors look like you but are not counted yet.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    ForEach(audit.suggestions.prefix(8)) { suggestion in
                        HStack(spacing: UIScale.pt(10)) {
                            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                                Text(suggestion.name + " <" + suggestion.email + ">")
                                    .font(.system(size: UIScale.pt(12), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Text(
                                    CodeStatsNumberFormat.grouped(suggestion.commits) + " commits, "
                                        + suggestion.reason.summary
                                )
                                .font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            Spacer()
                            Button("Count as me") { model.addIdentity(suggestion.value) }
                                .buttonStyle(.borderless)
                        }
                    }
                    if model.identityPendingRecount {
                        HStack {
                            Text("Identities changed. Refresh to recount.")
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            Spacer()
                            Button("Refresh now") { Task { await model.start() } }
                                .disabled(!model.canStart)
                        }
                    }
                }
                if !audit.duplicateRepositories.isEmpty {
                    if !audit.suggestions.isEmpty { Divider() }
                    ForEach(audit.duplicateRepositories.prefix(8), id: \.repository) { duplicate in
                        HStack(spacing: UIScale.pt(8)) {
                            Image(systemName: "square.on.square")
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(duplicate.repository + " repeats " + duplicate.original)
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(
                                CodeStatsNumberFormat.grouped(duplicate.shared)
                                    + " shared commits, "
                                    + CodeStatsNumberFormat.percent(duplicate.fraction * 100)
                            )
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
