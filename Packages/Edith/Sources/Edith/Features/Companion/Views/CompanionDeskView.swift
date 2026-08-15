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
        do {
            let client = client
            beliefs = try await client.beliefs(limit: 12)
            predictions = try await client.predictions(limit: 12)
            discrepancies = try await client.discrepancies(limit: 12)
            hypotheses = try await client.hypotheses(limit: 8)
            let queued = try await client.questions(limit: 5)
            budget = (queued.askedToday, queued.dailyBudget)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func askNext() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let outcome = try await client.nextQuestion()
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @State private var overrideTarget: CompanionDiscrepancy?
    @State private var overrideNote = ""

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if let error = model.error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.orange)
                }
                questionCard
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    beliefsCard
                    predictionsCard
                }
                discrepanciesCard
            }
            .pageContent(compact)
        }
        .task(id: generation) { if requestsEnabled { await model.refresh() } }
        .sheet(item: $overrideTarget) { discrepancy in
            overrideSheet(discrepancy)
        }
    }

    private var questionCard: some View {
        SkinCard(title: "Today", note: "what it wants to know", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                if let question = model.question {
                    Text(question.question)
                        .font(DashSkin.serif(UIScale.pt(16), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(question.motive)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    TextField("your answer", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...6)
                        .font(.system(size: UIScale.pt(12.5)))
                        .padding(UIScale.pt(8))
                        .background(DashSkin.paper2(dark))
                        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
                    HStack(spacing: UIScale.pt(8)) {
                        CompanionAsyncButton("Answer", filled: true, disabled: model.busy) {
                            await model.answer()
                        }
                        CompanionAsyncButton("Not now", disabled: model.busy) {
                            await model.skip()
                        }
                        CompanionAsyncButton(
                            "Never ask about \(question.topic)",
                            disabled: model.busy
                        ) {
                            await model.mute()
                        }
                    }
                } else if let resolution = model.lastResolution {
                    Text(resolution)
                        .font(.system(size: UIScale.pt(13)))
                        .foregroundStyle(DashSkin.ink(dark))
                    CompanionAsyncButton("Anything else?", disabled: model.busy) {
                        await model.askNext()
                    }
                } else {
                    Text(
                        model.budget.asked >= model.budget.total
                            ? "That is all it will ask today."
                            : "Nothing pressing. It keeps to \(model.budget.total) a day."
                    )
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    CompanionAsyncButton("What do you want to know?", disabled: model.busy) {
                        await model.askNext()
                    }
                }
                Text("\(model.budget.asked) of \(model.budget.total) asked today")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private var beliefsCard: some View {
        SkinCard(title: "Overnight", note: "what it concluded", dark: dark, fill: true) {
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
        SkinCard(title: "Resolved", note: "what it got right and wrong", dark: dark, fill: true) {
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
        SkinCard(title: "Waiting on you", note: "where the record disagreed", dark: dark) {
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
                            .buttonStyle(.plain)
                            .font(.system(size: UIScale.pt(11.5), weight: .medium))
                            .foregroundStyle(DashSkin.accent(dark))
                            .pointerCursor()
                        }
                    }
                }
            }
        }
    }

    private func overrideSheet(_ discrepancy: CompanionDiscrepancy) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text("What actually happened?")
                .font(DashSkin.serif(UIScale.pt(16), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text(discrepancy.claim)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            TextField("was pairing, not in git", text: $overrideNote, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .font(.system(size: UIScale.pt(12.5)))
                .padding(UIScale.pt(8))
                .background(DashSkin.paper2(dark))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
            HStack(spacing: UIScale.pt(8)) {
                CompanionAsyncButton("Save", filled: true, disabled: model.busy) {
                    await model.markReal(discrepancy, note: overrideNote)
                    overrideTarget = nil
                }
                Button("Cancel") { overrideTarget = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .pointerCursor()
            }
        }
        .padding(UIScale.pt(18))
        .frame(width: UIScale.pt(420))
        .background(DashSkin.paper(dark))
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(12)))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }
}
