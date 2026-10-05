import EdithKit
import Observation
import SwiftUI

@MainActor
@Observable
final class CompanionDeskModel: CompanionRefreshable {
    private(set) var question: CompanionQuestion?
    private(set) var budget: (asked: Int, total: Int) = (0, 3)
    private(set) var beliefs: [CompanionBelief] = []
    private(set) var predictions: [CompanionPrediction] = []
    private(set) var discrepancies: [CompanionDiscrepancy] = []
    private(set) var hypotheses: [CompanionHypothesis] = []
    private(set) var lastResolution: String?
    private(set) var busy = false
    let loading = ContentLoad()
    var loaded: Bool { loading.hasContent }
    private(set) var error: String?
    var draft = ""

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    var resolvedPredictions: [CompanionPrediction] {
        predictions.filter { $0.outcome != nil }
    }

    var openDiscrepancies: [CompanionDiscrepancy] {
        discrepancies.filter { !$0.dismissed }
    }

    func refresh() async {
        let client = client
        await loading.perform(operation: {
            async let beliefs = client.beliefs(limit: 12)
            async let predictions = client.predictions(limit: 12)
            async let discrepancies = client.discrepancies(limit: 12)
            async let hypotheses = client.hypotheses(limit: 8)
            async let queued = client.questions(limit: 5)
            return try await (beliefs, predictions, discrepancies, hypotheses, queued)
        }) { result in
            self.beliefs = result.0
            self.predictions = result.1
            self.discrepancies = result.2
            self.hypotheses = result.3
            budget = (result.4.askedToday, result.4.dailyBudget)
            error = nil
        }
        if let message = loading.errorMessage { error = message }
    }

    func askNext() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let client = client
            let outcome = try await CompanionMindRuntimeOperationExecution.nextQuestion {
                try await client.nextQuestion()
            }
            question = outcome.question
            if let asked = outcome.askedToday, let total = outcome.dailyBudget {
                budget = (asked, total)
            }
            lastResolution = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func answer() async {
        guard let question, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !busy
        else { return }
        busy = true
        defer { busy = false }
        do {
            let outcome = try await client.answerQuestion(id: question.id, answer: draft)
            lastResolution = outcome.resolution
            budget = (outcome.askedToday, budget.total)
            draft = ""
            self.question = nil
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func skip() async {
        guard let question, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.skipQuestion(id: question.id)
            self.question = nil
            draft = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func mute() async {
        guard let question, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.muteTopic(question.topic)
            self.question = nil
            draft = ""
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func markReal(_ discrepancy: CompanionDiscrepancy, note: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.overrideDiscrepancy(id: discrepancy.id, real: note)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CompanionDeskScreen: View {
    @Bindable var model: CompanionDeskModel
    var isActive = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @State private var refreshedGeneration = -1
    @State private var overrideTarget: CompanionDiscrepancy?
    @State private var overrideNote = ""

    private var dark: Bool { scheme == .dark }

    var body: some View {
        PageScaffold(pinnedHeader: true, header: {}) {
            if model.loaded, let error = model.error {
                PageNotice(error, tone: .error)
            }
            PageLoading(
                state: model.loading.state,
                message: model.loading.errorMessage
                    ?? "The companion desk could not be loaded.",
                layout: .cards, refreshing: model.loading.isRefreshing,
                retry: { Task { await model.refresh() } }
            ) {
                questionCard
                PageGrid {
                    beliefsCard
                } secondary: {
                    predictionsCard
                } full: {
                    discrepanciesCard
                }
            }
        }
        .pageTask(
            id: generation, active: isActive && requestsEnabled, cancel: { model.loading.cancel() }
        ) {
            guard isActive, requestsEnabled, refreshedGeneration != generation else { return }
            await model.refresh()
            if !Task.isCancelled { refreshedGeneration = generation }
        }
        .edithSheet(item: $overrideTarget, dismissible: false) { discrepancy in
            overrideSheet(discrepancy)
        }
    }

    private var questionCard: some View {
        PageCard(title: "Today", note: "what it wants to know") {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                if let question = model.question {
                    Text(question.question)
                        .font(DashSkin.heading(16, weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(question.motive)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    AnswerField(placeholder: "your answer", text: $model.draft) {
                        Task { await model.answer() }
                    }
                    WrapHStack(spacing: UIScale.pt(8)) {
                        CompanionButton(
                            title: "Answer", role: .primary, busy: model.busy
                        ) {
                            Task { await model.answer() }
                        }
                        CompanionButton(title: "Not now", disabled: model.busy) {
                            Task { await model.skip() }
                        }
                        CompanionButton(
                            title: "Never ask about this", disabled: model.busy
                        ) {
                            Task { await model.mute() }
                        }
                        .help("Never ask about \(question.topic)")
                    }
                } else if let resolution = model.lastResolution {
                    Text(resolution)
                        .font(.system(size: UIScale.pt(13)))
                        .foregroundStyle(DashSkin.ink(dark))
                    CompanionButton(title: "Anything else?", disabled: model.busy) {
                        Task { await model.askNext() }
                    }
                } else {
                    Text(
                        model.budget.asked >= model.budget.total
                            ? "That is all it will ask today."
                            : "Nothing pressing. It keeps to \(model.budget.total) a day."
                    )
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    CompanionButton(title: "What do you want to know?", disabled: model.busy) {
                        Task { await model.askNext() }
                    }
                }
                Text("\(model.budget.asked) of \(model.budget.total) asked today")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private var beliefsCard: some View {
        PageCard(title: "Overnight", note: "what it concluded", fill: true) {
            if model.beliefs.isEmpty {
                emptyText("Nothing formed yet.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    ForEach(model.beliefs.prefix(6), id: \.id) { belief in
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(belief.statement)
                                .font(.system(size: UIScale.pt(12.5)))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(2)
                            Text("\(Int(belief.confidence * 100))% confident")
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    ForEach(model.hypotheses.prefix(3), id: \.id) { hypothesis in
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(hypothesis.statement)
                                .font(.system(size: UIScale.pt(12.5)))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(2)
                            Text("theory, \(hypothesis.status), because \(hypothesis.mechanism)")
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var predictionsCard: some View {
        PageCard(title: "Resolved", note: "what it got right and wrong", fill: true) {
            if model.resolvedPredictions.isEmpty {
                emptyText("No prediction has come due yet.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    ForEach(model.resolvedPredictions.prefix(6), id: \.id) { prediction in
                        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
                            Text(prediction.statement)
                                .font(.system(size: UIScale.pt(12.5)))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            MindChip(
                                label: prediction.outcome ?? "open",
                                tone: prediction.outcome == "confirmed" ? .green : .orange)
                        }
                    }
                }
            }
        }
    }

    private var discrepanciesCard: some View {
        PageCard(title: "Waiting on you", note: "where the record disagreed") {
            if model.openDiscrepancies.isEmpty {
                emptyText("Nothing has diverged from the record.")
            } else {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    ForEach(model.openDiscrepancies, id: \.id) { discrepancy in
                        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                Text(discrepancy.claim)
                                    .font(.system(size: UIScale.pt(12.5)))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(2)
                                Text(discrepancy.kind.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: UIScale.pt(11)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                            }
                            Spacer(minLength: 0)
                            Button("This was real") {
                                overrideNote = ""
                                overrideTarget = discrepancy
                            }
                            .buttonStyle(.edith(.borderless))
                            .font(.system(size: UIScale.pt(11.5), weight: .medium))
                            .foregroundStyle(DashSkin.accent(dark))
                        }
                    }
                }
            }
        }
    }

    private func overrideSheet(_ discrepancy: CompanionDiscrepancy) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("What actually happened?")
                .font(DashSkin.heading(16, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text(discrepancy.claim)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            AnswerField(placeholder: "was pairing, not in git", text: $overrideNote) {
                Task {
                    await model.markReal(discrepancy, note: overrideNote)
                    overrideTarget = nil
                }
            }
            HStack(spacing: UIScale.pt(8)) {
                Spacer()
                CompanionButton(title: "Cancel", disabled: model.busy) { overrideTarget = nil }
                    .keyboardShortcut(.cancelAction)
                CompanionButton(title: "Save", role: .primary, busy: model.busy) {
                    Task {
                        await model.markReal(discrepancy, note: overrideNote)
                        overrideTarget = nil
                    }
                }
            }
        }
        .padding(UIScale.pt(18))
        .frame(width: PresentationMetrics.width(420))
        .background(DashSkin.paper(dark))
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }
}
