import Foundation

public struct AttentionJevCategorizer: Sendable {
    public static let purpose = "attention.categorize"
    public static let question = "category"
    public static let entityThreshold = 0.55
    public static let titleThreshold = 0.6
    public static let minimumEntity: TimeInterval = 120
    public static let minimumTitle: TimeInterval = 60
    public static let retryAfter: TimeInterval = 14 * 86_400
    public static let maximumTitles = 5_000

    public struct EntityCandidate: Equatable, Sendable {
        public var key: String
        public var name: String
        public var identifier: String
        public var isWebsite: Bool
        public var titles: [String]
    }

    public struct TitleCandidate: Equatable, Sendable {
        public var key: String
        public var site: String
        public var title: String
    }

    public var entityLimit: Int
    public var titleLimit: Int

    public init(entityLimit: Int = 16, titleLimit: Int = 40) {
        self.entityLimit = entityLimit
        self.titleLimit = titleLimit
    }

    public func candidates(
        summary: AttentionSummary, classifications: AttentionClassifications, now: Date
    ) -> (entities: [EntityCandidate], titles: [TitleCandidate]) {
        func due(_ decision: AttentionJevDecision?) -> Bool {
            guard let decision else { return true }
            return !decision.isDecisive
                && now.timeIntervalSince(decision.decidedAt) > Self.retryAfter
        }
        var entities: [EntityCandidate] = []
        var titles: [TitleCandidate] = []
        for entity in summary.entities {
            if entity.categorySource == .none, entity.duration >= Self.minimumEntity,
                entity.id.hasPrefix("app:") || entity.id.hasPrefix("web:"),
                due(classifications.entities[entity.id]), entities.count < entityLimit
            {
                entities.append(
                    EntityCandidate(
                        key: entity.id, name: entity.name,
                        identifier: String(entity.id.dropFirst(4)),
                        isWebsite: entity.id.hasPrefix("web:"),
                        titles: entity.details.prefix(5).map(\.name)))
            }
            guard let domain = entity.domain,
                AttentionCatalog.mixedDomains.contains(where: {
                    domain == $0 || domain.hasSuffix("." + $0)
                })
            else { continue }
            for detail in entity.details
            where detail.duration >= Self.minimumTitle
                && detail.name != AttentionText.location(detail.url) && titles.count < titleLimit
            {
                let key = AttentionClassifications.titleKey(
                    entityID: "web:\(domain)", title: detail.name)
                guard due(classifications.titles[key]) else { continue }
                titles.append(TitleCandidate(key: key, site: domain, title: detail.name))
            }
        }
        return (entities, titles)
    }

    public func options(_ settings: AttentionSettings) -> [JevOption] {
        settings.categories.filter { $0.kind != .unclassified }.prefix(
            JevQuestion.maximumOptions - 1
        ).map {
            JevOption($0.id, AttentionCatalog.descriptions[$0.id] ?? $0.name)
        } + [JevOption(AttentionJevDecision.none, "cannot tell from this information")]
    }

    public func request(_ candidate: EntityCandidate, options: [JevOption]) -> JevRequest {
        JevRequest(
            state: .fields([
                "name": candidate.name,
                "type": candidate.isWebsite ? "website" : "macOS application",
                "identifier": candidate.identifier,
                "titles": candidate.titles.map { JevText.compact($0, limit: 160) }
                    .joined(separator: "\n"),
            ]),
            questions: [
                Self.question: .choice(
                    "Which category best describes time spent in this `type` called `name` (`identifier`), judging by its window `titles`?",
                    options: options)
            ])
    }

    public func request(_ candidate: TitleCandidate, options: [JevOption]) -> JevRequest {
        JevRequest(
            state: .fields([
                "site": candidate.site, "title": JevText.compact(candidate.title, limit: 200),
            ]),
            questions: [
                Self.question: .choice(
                    "Which category best describes reading or watching the page `title` on `site`?",
                    options: options)
            ])
    }

    public func run(
        summary: AttentionSummary, settings: AttentionSettings,
        classifications: AttentionClassifications, decider: JevDeciding, now: Date = Date()
    ) async -> (AttentionClassifications, AttentionCategorizeReport) {
        var next = classifications
        var report = AttentionCategorizeReport(available: true)
        let options = options(settings)
        let valid = Set(options.map(\.id))
        let (entities, titles) = candidates(
            summary: summary, classifications: classifications, now: now)
        for candidate in entities {
            guard !Task.isCancelled,
                let answer = try? await decider.decide(
                    request(candidate, options: options), purpose: Self.purpose
                ).answer(Self.question)
            else { break }
            next.entities[candidate.key] = decision(
                answer, threshold: Self.entityThreshold, valid: valid, now: now)
            report.entities += 1
        }
        for candidate in titles {
            guard !Task.isCancelled,
                let answer = try? await decider.decide(
                    request(candidate, options: options), purpose: Self.purpose
                ).answer(Self.question)
            else { break }
            next.titles[candidate.key] = decision(
                answer, threshold: Self.titleThreshold, valid: valid, now: now)
            report.titles += 1
        }
        if next.titles.count > Self.maximumTitles {
            let keep = next.titles.sorted { $0.value.decidedAt > $1.value.decidedAt }
                .prefix(Self.maximumTitles)
            next.titles = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return (next, report)
    }

    private func decision(
        _ answer: JevAnswer, threshold: Double, valid: Set<String>, now: Date
    ) -> AttentionJevDecision {
        let probability = answer.chosenProbability ?? 0
        guard let choice = answer.choice, valid.contains(choice), probability >= threshold else {
            return AttentionJevDecision(
                categoryID: AttentionJevDecision.none, confidence: probability, decidedAt: now)
        }
        return AttentionJevDecision(categoryID: choice, confidence: probability, decidedAt: now)
    }
}
