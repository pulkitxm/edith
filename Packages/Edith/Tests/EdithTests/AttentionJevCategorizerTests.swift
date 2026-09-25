import Foundation
import Testing

@testable import EdithKit

private actor AttentionScriptedJev: JevDeciding {
    var requests: [JevRequest] = []
    let answer: @Sendable (JevRequest) -> (String, Double)

    init(answer: @escaping @Sendable (JevRequest) -> (String, Double)) {
        self.answer = answer
    }

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        requests.append(request)
        let (choice, probability) = answer(request)
        return JevDecision(
            response: JevResponse(
                model: "test",
                answers: [
                    AttentionJevCategorizer.question: JevAnswer(
                        type: "choice", choice: choice, probabilities: [choice: probability]),
                    AttentionJevCategorizer.productivityQuestion: JevAnswer(
                        type: "choice", choice: "productive", probabilities: ["productive": 0.7]),
                    AttentionJevCategorizer.sphereQuestion: JevAnswer(
                        type: "choice", choice: "personal", probabilities: ["personal": 0.3]),
                ]),
            milliseconds: 1)
    }
}

@Suite struct AttentionJevCategorizerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func field(_ request: JevRequest, _ key: String) -> String? {
        guard case .fields(let fields) = request.state else { return nil }
        return fields[key]
    }

    private func summary() -> AttentionSummary {
        let events = [
            AttentionEvent(
                startedAt: now, duration: 600, source: .application, appName: "Mystery",
                bundleID: "com.example.Mystery", windowTitle: "Canvas"),
            AttentionEvent(
                startedAt: now.addingTimeInterval(600), duration: 300, source: .browser,
                appName: "Chrome", windowTitle: "Building a compiler in Swift",
                url: "https://www.youtube.com/watch", domain: "www.youtube.com"),
            AttentionEvent(
                startedAt: now.addingTimeInterval(900), duration: 30, source: .application,
                appName: "Brief", bundleID: "com.example.Brief"),
        ]
        return AttentionAnalyzer().summary(
            events: events, settings: AttentionSettings(), from: now,
            to: now.addingTimeInterval(3_600))
    }

    @Test func onlyUnclassifiedEntitiesAndMixedSiteTitlesAreAsked() {
        let candidates = AttentionJevCategorizer().candidates(
            summary: summary(), classifications: .init(), now: now)
        #expect(candidates.entities.map(\.key) == ["app:com.example.Mystery"])
        #expect(candidates.entities.first?.titles == ["Canvas"])
        #expect(candidates.titles.map(\.title) == ["Building a compiler in Swift"])
        #expect(candidates.titles.first?.site == "youtube.com")
    }

    @Test func confidentAnswersBecomeDecisionsAndDoubtfulOnesAreRemembered() async {
        let jev = AttentionScriptedJev { request in
            if case .fields(let fields) = request.state, fields["site"] != nil {
                return ("learning", 0.9)
            }
            return ("design", 0.3)
        }
        let (next, report) = await AttentionJevCategorizer().run(
            summary: summary(), settings: AttentionSettings(), classifications: .init(),
            decider: jev, now: now)
        #expect(report.entities == 1)
        #expect(report.titles == 1)
        #expect(next.entities["app:com.example.Mystery"]?.isDecisive == false)
        let key = AttentionClassifications.titleKey(
            entityID: "web:youtube.com", title: "Building a compiler in Swift")
        #expect(next.titles[key]?.categoryID == "learning")
        let again = AttentionJevCategorizer().candidates(
            summary: summary(), classifications: next, now: now)
        #expect(again.entities.isEmpty)
        #expect(again.titles.isEmpty)
        let later = AttentionJevCategorizer().candidates(
            summary: summary(), classifications: next, now: now.addingTimeInterval(15 * 86_400))
        #expect(later.entities.count == 1)
        let requests = await jev.requests
        #expect(field(requests[0], "identifier") == "com.example.Mystery")
    }

    @Test func optionsSkipUnclassifiedAndOfferAnEscape() {
        let options = AttentionJevCategorizer().options(AttentionSettings())
        #expect(!options.contains { $0.id == AttentionCatalog.unclassified })
        #expect(options.last?.id == AttentionJevDecision.none)
        #expect(options.contains { $0.id == "agents" })
    }

    @Test func requestsCarryRichEvidenceAndThePersonsPreferences() async {
        var settings = AttentionSettings()
        settings.profileNote = "I build developer tools."
        settings.rules = [
            AttentionIdentityRule(
                name: "X", categoryID: "social", domains: ["x.com"], productivity: .productive)
        ]
        let categorizer = AttentionJevCategorizer(describeApp: { _ in "App Store category design" })
        let candidates = categorizer.candidates(
            summary: summary(), classifications: .init(), now: now)
        let request = categorizer.request(
            candidates.entities[0], settings: settings, options: categorizer.options(settings))
        #expect(field(request, "about_the_person") == "I build developer tools.")
        #expect(
            field(request, "how_the_person_classified_other_things")?.contains(
                "X (x.com): Social, productive") == true)
        #expect(field(request, "description") == "App Store category design")
        #expect(field(request, "usage")?.hasPrefix("10 minutes over 1 visits") == true)
        #expect(
            Set(request.questions.keys) == [
                AttentionJevCategorizer.question, AttentionJevCategorizer.productivityQuestion,
                AttentionJevCategorizer.sphereQuestion,
            ])
        let jev = AttentionScriptedJev { _ in ("design", 0.9) }
        let (next, _) = await categorizer.run(
            summary: summary(), settings: settings, classifications: .init(), decider: jev,
            now: now)
        let decision = next.entities["app:com.example.Mystery"]
        #expect(decision?.categoryID == "design")
        #expect(decision?.productivity == .productive)
        #expect(decision?.sphere == nil)
    }
}
