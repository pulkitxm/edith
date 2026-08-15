import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionMindModel: CompanionRefreshable {
    private(set) var beliefs: [CompanionBelief] = []
    private(set) var claims: [CompanionClaim] = []
    private(set) var observations: [CompanionObservation] = []
    private(set) var runs: [CompanionRun] = []
    private(set) var core: [CompanionCoreSection] = []
    private(set) var calibration: [CompanionCalibration] = []
    private(set) var savingCore = false
    private(set) var runningNightly = false
    private(set) var error: String?

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func refresh() async {
        do {
            let client = client
            beliefs = try await client.beliefs(limit: 30)
            claims = try await client.claims(limit: 30)
            observations = try await client.observations(limit: 40, kind: nil)
            runs = try await client.runs(limit: 5)
            core = (try? await client.core()) ?? []
            calibration = (try? await client.calibration()) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveCore(section: String, content: String) async {
        guard !savingCore else { return }
        savingCore = true
        defer { savingCore = false }
        do {
            _ = try await client.writeCore(section: section, content: content)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runNightly() async {
        guard !runningNightly else { return }
        runningNightly = true
        defer { runningNightly = false }
        do {
            _ = try await client.nightlyRun()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum MindDetail: Identifiable {
    case belief(CompanionBelief)
    case claim(CompanionClaim)
    case observation(CompanionObservation)

    var id: String {
        switch self {
        case let .belief(belief): return "belief-\(belief.id)"
        case let .claim(claim): return "claim-\(claim.id)"
        case let .observation(observation): return "observation-\(observation.id)"
        }
    }
}

struct CompanionMindScreen: View {
    let model: CompanionMindModel
    var openEpisode: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @State private var barsFilled = false
    @State private var detail: MindDetail?
    @State private var editingSection: String?
    @State private var sectionDraft = ""

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if let error = model.error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    beliefsCard
                    VStack(spacing: UIScale.pt(12)) {
                        claimsCard
                        nightlyCard
                    }
                }
                coreCard
                calibrationCard
                observationsCard
            }
            .pageContent(compact)
        }
        .task(id: generation) {
            if requestsEnabled { await model.refresh() }
            withAnimation(Motion.animation(Motion.settle, reduceMotion: reduceMotion)) {
                barsFilled = true
            }
        }
        .sheet(item: $detail) { detail in
            MindDetailSheet(detail: detail, dark: dark, openEpisode: openEpisode) {
                self.detail = nil
            }
        }
    }

    private var coreCard: some View {
        SkinCard(title: "Who you are", note: "always in context", dark: dark) {
            if model.core.isEmpty {
                emptyText("Empty until the nightly run writes it, or until you write it yourself.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    ForEach(model.core, id: \.section) { section in
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            HStack(spacing: UIScale.pt(8)) {
                                Text(section.section.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                                    .foregroundStyle(DashSkin.ink(dark))
                                Spacer(minLength: 0)
                                Text("by \(section.updatedBy)")
                                    .font(.system(size: UIScale.pt(10.5)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                Button(editingSection == section.section ? "Cancel" : "Edit") {
                                    if editingSection == section.section {
                                        editingSection = nil
                                    } else {
                                        editingSection = section.section
                                        sectionDraft = section.content
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.accent(dark))
                                .pointerCursor()
                            }
                            if editingSection == section.section {
                                TextField("", text: $sectionDraft, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .lineLimit(2...8)
                                    .font(.system(size: UIScale.pt(12.5)))
                                    .padding(UIScale.pt(8))
                                    .background(DashSkin.paper2(dark))
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: UIScale.pt(8)))
                                Button("Save") {
                                    let draft = sectionDraft
                                    let name = section.section
                                    editingSection = nil
                                    Task { await model.saveCore(section: name, content: draft) }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                                .foregroundStyle(DashSkin.accent(dark))
                                .pointerCursor()
                            } else {
                                Text(section.content)
                                    .font(.system(size: UIScale.pt(12.5)))
                                    .foregroundStyle(DashSkin.inkSoft(dark))
                            }
                        }
                    }
                }
            }
        }
    }

    private var calibrationCard: some View {
        SkinCard(title: "Calibration", note: "in both directions", dark: dark) {
            if model.calibration.isEmpty {
                emptyText("Nothing scored yet; this needs claims and records to compare.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    ForEach(model.calibration, id: \.domain) { row in
                        HStack(spacing: UIScale.pt(8)) {
                            Text(row.domain.replacingOccurrences(of: "_", with: " "))
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(DashSkin.ink(dark))
                            MindChip(
                                label: row.direction.replacingOccurrences(of: "_", with: " "),
                                tone: row.direction == "accurate" ? .green : .orange)
                            Spacer(minLength: 0)
                            Text("\(row.samples) times")
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                }
            }
        }
    }

    private var beliefsCard: some View {
        SkinCard(title: "Beliefs", note: "what it concluded", dark: dark, fill: true) {
            if model.beliefs.isEmpty {
                emptyText("Nothing concluded yet. The nightly run forms beliefs from episodes.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(model.beliefs, id: \.id) { belief in
                        beliefRow(belief)
                    }
                }
            }
        }
    }

    private func beliefRow(_ belief: CompanionBelief) -> some View {
        let superseded = belief.status != "active"
        return MindRow(dark: dark) {
            detail = .belief(belief)
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
                    Text(belief.statement)
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if superseded {
                        MindChip(label: "superseded", tone: .orange)
                    } else {
                        Text("\(Int(belief.confidence * 100))%")
                            .font(.system(size: UIScale.pt(11)))
                            .monospacedDigit()
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
                if !superseded {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DashSkin.line(dark))
                            Capsule()
                                .fill(DashSkin.accent(dark))
                                .frame(
                                    width: barsFilled
                                        ? geometry.size.width * CGFloat(belief.confidence) : 0)
                        }
                    }
                    .frame(height: UIScale.pt(5))
                }
            }
            .opacity(superseded ? 0.55 : 1)
        }
    }

    private var claimsCard: some View {
        SkinCard(title: "Claims", note: "checked against reality", dark: dark) {
            if model.claims.isEmpty {
                emptyText("No claims extracted yet.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    ForEach(model.claims.prefix(9), id: \.id) { claim in
                        MindRow(dark: dark) {
                            detail = .claim(claim)
                        } content: {
                            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
                                Text(claim.statement)
                                    .font(.system(size: UIScale.pt(12.5)))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                claimVerdict(claim)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func claimVerdict(_ claim: CompanionClaim) -> some View {
        switch claim.verdict {
        case "corroborated":
            MindChip(label: "corroborated", tone: .green)
        case "contradicted":
            MindChip(label: "contradicted", tone: .red)
        case .some:
            MindChip(label: "unclear", tone: .orange)
        case nil:
            MindChip(label: "unchecked", tone: DashSkin.inkFaint(dark))
        }
    }

    private var observationsCard: some View {
        SkinCard(
            title: "Observed activity", note: "what the connectors saw", dark: dark
        ) {
            if model.observations.isEmpty {
                emptyText("No observations yet. Sync GitHub from Settings.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        ForEach(model.observations, id: \.id) { observation in
                            MindRow(dark: dark) {
                                detail = .observation(observation)
                            } content: {
                                HStack(spacing: UIScale.pt(8)) {
                                    Text(observation.kind)
                                        .font(.system(size: UIScale.pt(10)))
                                        .foregroundStyle(DashSkin.inkFaint(dark))
                                        .frame(width: UIScale.pt(84), alignment: .leading)
                                    Text(observation.summary)
                                        .font(.system(size: UIScale.pt(12)))
                                        .foregroundStyle(DashSkin.ink(dark))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(String(observation.observedAt.prefix(10)))
                                        .font(.system(size: UIScale.pt(10.5)))
                                        .monospacedDigit()
                                        .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: UIScale.pt(260))
            }
        }
    }

    private var nightlyCard: some View {
        SkinCard(
            title: "Nightly run",
            note: model.runningNightly ? "running…" : "02:00 on the companion",
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                Button(model.runningNightly ? "Running the pipeline…" : "Run now") {
                    Task { await model.runNightly() }
                }
                .disabled(model.runningNightly)
                if let run = model.runs.first {
                    Text(runSummary(run))
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    stepChips(run)
                } else {
                    emptyText("No runs yet. The scheduler fires at 02:00, or run it now.")
                }
            }
        }
    }

    private func runSummary(_ run: CompanionRun) -> String {
        let when = String(run.startedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
        return run.ok ? "Last run \(when), all steps green" : "Last run \(when)"
    }

    private func stepChips(_ run: CompanionRun) -> some View {
        FlowChips(spacing: UIScale.pt(6)) {
            ForEach(Array(run.steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: UIScale.pt(4)) {
                    Image(systemName: step.ok ? "checkmark" : "xmark")
                        .font(.system(size: UIScale.pt(8.5), weight: .bold))
                        .foregroundStyle(step.ok ? .green : .red)
                    Text(step.name.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(3))
                .fixedSize(horizontal: true, vertical: false)
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(7))
                        .strokeBorder(DashSkin.line(dark))
                }
                .help(step.detail ?? step.name)
            }
        }
    }

    private func emptyText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }
}

private struct MindRow<Content: View>: View {
    let dark: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    hovering ? DashSkin.accent(dark).opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering = $0 }
        .help("Open the full record")
    }
}

struct MindChip: View {
    let label: String
    let tone: Color

    var body: some View {
        Text(label)
            .font(.system(size: UIScale.pt(9.5), weight: .bold))
            .tracking(0.4)
            .foregroundStyle(tone)
            .padding(.horizontal, UIScale.pt(7))
            .padding(.vertical, UIScale.pt(2))
            .background(tone.opacity(0.14), in: Capsule())
    }
}

private struct MindDetailSheet: View {
    let detail: MindDetail
    let dark: Bool
    let openEpisode: (String) -> Void
    let close: () -> Void
    @State private var episodeRefs: [(String, String)] = []
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    private var contextIds: [String] {
        switch detail {
        case let .belief(belief): return belief.evidenceEpisodeIds
        case let .claim(claim): return claim.episodeId.map { [$0] } ?? []
        case .observation: return []
        }
    }

    private func loadRefs() async {
        var refs: [(String, String)] = []
        for id in contextIds {
            if let episode = try? await client.episodeDetail(id: id) {
                let date = String(episode.occurredAt.prefix(10))
                refs.append((id, "\(episode.title) · \(episode.kind) · \(date)"))
            } else {
                refs.append((id, "episode \(String(id.prefix(8)))…"))
            }
        }
        episodeRefs = refs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline) {
                Text(eyebrow)
                    .font(.system(size: UIScale.pt(10), weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DashSkin.accent(dark))
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: UIScale.pt(15)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Close")
            }
            content
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(460), height: UIScale.pt(360), alignment: .topLeading)
        .background(DashSkin.paper(dark))
        .task(id: generation) {
            if requestsEnabled { await loadRefs() }
        }
    }

    private func contextRows(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(label)
                .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(DashSkin.inkFaint(dark))
                .padding(.top, UIScale.pt(4))
            if episodeRefs.isEmpty {
                Text("Loading the involved episodes…")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            ForEach(Array(episodeRefs.enumerated()), id: \.offset) { _, ref in
                Button {
                    close()
                    openEpisode(ref.0)
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Image(systemName: "book.pages")
                            .font(.system(size: UIScale.pt(10)))
                        Text(ref.1)
                            .font(.system(size: UIScale.pt(11.5)))
                            .lineLimit(1)
                    }
                    .foregroundStyle(DashSkin.accent(dark))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Open this episode in Library")
            }
        }
    }

    private var eyebrow: String {
        switch detail {
        case .belief: return "BELIEF"
        case .claim: return "CLAIM"
        case .observation: return "OBSERVED"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch detail {
        case let .belief(belief):
            beliefDetail(belief)
        case let .claim(claim):
            claimDetail(claim)
        case let .observation(observation):
            observationDetail(observation)
        }
    }

    @ViewBuilder
    private func beliefDetail(_ belief: CompanionBelief) -> some View {
        Text(belief.statement)
            .font(DashSkin.serif(UIScale.pt(18), weight: .semibold))
            .foregroundStyle(DashSkin.ink(dark))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        HStack(spacing: UIScale.pt(8)) {
            MindChip(
                label: belief.status == "active" ? "active" : belief.status,
                tone: belief.status == "active" ? .green : .orange)
            MindChip(label: belief.kind, tone: DashSkin.inkFaint(dark))
            Text("\(Int(belief.confidence * 100))% confident")
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
        Text("First formed \(String(belief.firstFormed.prefix(10)))")
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
        if !belief.evidenceEpisodeIds.isEmpty {
            ScrollView {
                contextRows("EVIDENCE · \(belief.evidenceEpisodeIds.count) EPISODES")
            }
        }
    }

    @ViewBuilder
    private func claimDetail(_ claim: CompanionClaim) -> some View {
        Text(claim.statement)
            .font(DashSkin.serif(UIScale.pt(18), weight: .semibold))
            .foregroundStyle(DashSkin.ink(dark))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        HStack(spacing: UIScale.pt(8)) {
            switch claim.verdict {
            case "corroborated": MindChip(label: "corroborated", tone: .green)
            case "contradicted": MindChip(label: "contradicted", tone: .red)
            case .some: MindChip(label: "unclear", tone: .orange)
            case nil: MindChip(label: "unchecked", tone: DashSkin.inkFaint(dark))
            }
            MindChip(label: claim.claimType, tone: DashSkin.inkFaint(dark))
            if claim.testable {
                MindChip(label: "testable", tone: DashSkin.accent(dark))
            }
        }
        Text("Asserted \(String(claim.assertedAt.prefix(10)))")
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
        if let note = claim.verdictNote, !note.isEmpty {
            Text(note)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(UIScale.pt(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        }
        if claim.episodeId != nil {
            contextRows("SAID IN")
        }
        if let observations = claim.observationIds, !observations.isEmpty {
            Text("Checked against \(observations.count) observations")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }

    @ViewBuilder
    private func observationDetail(_ observation: CompanionObservation) -> some View {
        Text(observation.summary)
            .font(DashSkin.serif(UIScale.pt(17), weight: .semibold))
            .foregroundStyle(DashSkin.ink(dark))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        HStack(spacing: UIScale.pt(8)) {
            MindChip(label: observation.kind, tone: DashSkin.accent(dark))
            MindChip(label: observation.source, tone: DashSkin.inkFaint(dark))
        }
        Text("Observed \(observation.observedAt)")
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }
}
