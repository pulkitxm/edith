import AppKit
import Foundation

public enum AttentionAppDescriptor {
    public static func describe(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let info = Bundle(url: url)?.infoDictionary
        else { return nil }
        var parts: [String] = []
        if let name = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String {
            parts.append("named \(name)")
        }
        if let category = info["LSApplicationCategoryType"] as? String {
            let readable = category.replacingOccurrences(of: "public.app-category.", with: "")
                .replacingOccurrences(of: "-", with: " ")
            parts.append("App Store category \(readable)")
        }
        if let vendor = info["NSHumanReadableCopyright"] as? String, !vendor.isEmpty {
            parts.append("made by \(String(vendor.prefix(80)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

public struct AttentionJevCategorizer: Sendable {
    public static let purpose = "attention.categorize"
    public static let question = "category"
    public static let productivityQuestion = "productivity"
    public static let sphereQuestion = "sphere"
    public static let entityThreshold = 0.55
    public static let titleThreshold = 0.6
    public static let axisThreshold = 0.45
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
        public var paths: [String]
        public var about: String?
        public var usage: String
    }

    public struct TitleCandidate: Equatable, Sendable {
        public var key: String
        public var site: String
        public var title: String
        public var siteName: String
    }

    public var entityLimit: Int
    public var titleLimit: Int
    public var describeApp: @Sendable (String) -> String?

    public init(
        entityLimit: Int = 16, titleLimit: Int = 40,
        describeApp: @escaping @Sendable (String) -> String? = { _ in nil }
    ) {
        self.entityLimit = entityLimit
        self.titleLimit = titleLimit
        self.describeApp = describeApp
    }

    static func usage(_ entity: AttentionEntity) -> String {
        let minutes = max(entity.duration / 60, 1)
        let visits = max(entity.visits, 1)
        let perVisit = Int((entity.duration / Double(visits) / 60).rounded())
        var parts = [
            "\(Int(minutes.rounded())) minutes over \(visits) visits, about \(perVisit) minutes each"
        ]
        if entity.signals.interactions > 0 {
            parts.append(
                String(
                    format: "%.0f keystrokes, %.0f clicks and %.0f scrolls per minute",
                    Double(entity.signals.keys) / minutes, Double(entity.signals.clicks) / minutes,
                    Double(entity.signals.scrolls) / minutes))
        }
        return parts.joined(separator: "; ")
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
                let identifier = String(entity.id.dropFirst(4))
                let isWebsite = entity.id.hasPrefix("web:")
                entities.append(
                    EntityCandidate(
                        key: entity.id, name: entity.name, identifier: identifier,
                        isWebsite: isWebsite,
                        titles: entity.details.prefix(8).map(\.name),
                        paths: Array(
                            Set(entity.details.compactMap { AttentionText.location($0.url) })
                                .prefix(5)),
                        about: isWebsite ? entity.about : describeApp(identifier),
                        usage: Self.usage(entity)))
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
                titles.append(
                    TitleCandidate(
                        key: key, site: domain, title: detail.name, siteName: entity.name))
            }
        }
        return (entities, titles)
    }

    public func options(_ settings: AttentionSettings) -> [JevOption] {
        settings.categories.filter { !$0.isUnclassified }.prefix(JevQuestion.maximumOptions - 1)
            .map {
                JevOption(
                    $0.id,
                    "\($0.name): \(AttentionCatalog.descriptions[$0.id] ?? "time spent on \($0.name.lowercased())")"
                )
            } + [JevOption(AttentionJevDecision.none, "cannot tell from this information")]
    }

    public static func preferences(_ settings: AttentionSettings) -> String {
        let explicit = settings.rules.filter { $0.productivity != nil || $0.sphere != nil }
        let rest = settings.rules.filter { $0.productivity == nil && $0.sphere == nil }
        return (explicit + rest).prefix(24).map { rule in
            let category = settings.category(rule.categoryID)
            let targets = (rule.domains + rule.bundleIDs + rule.urls).prefix(3)
                .joined(separator: ", ")
            let productivity = (rule.productivity ?? category.productivity).title.lowercased()
            let sphere = (rule.sphere ?? category.sphere).title.lowercased()
            return "\(rule.name) (\(targets)): \(category.name), \(productivity), \(sphere)"
        }.joined(separator: "\n")
    }

    private func context(_ settings: AttentionSettings) -> [String: String] {
        var fields: [String: String] = [:]
        let note = settings.profileNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { fields["about_the_person"] = JevText.compact(note, limit: 800) }
        let preferences = Self.preferences(settings)
        if !preferences.isEmpty { fields["how_the_person_classified_other_things"] = preferences }
        return fields
    }

    private func questions(
        _ subject: String, settings: AttentionSettings, options: [JevOption]
    ) -> [String: JevQuestion] {
        [
            Self.question: .choice(
                "Which category best describes \(subject)? Use `about_the_person` and `how_the_person_classified_other_things` when present, so the answer matches this person rather than a typical user.",
                options: options),
            Self.productivityQuestion: .choice(
                "For this particular person, how does \(subject) affect their goals?",
                options: AttentionProductivity.ranked.map {
                    JevOption($0.identifier, "\($0.title): \($0.meaning)")
                }),
            Self.sphereQuestion: .choice(
                "Is \(subject) part of this person's work, their personal life, or both?",
                options: AttentionSphere.allCases.map {
                    JevOption($0.rawValue, $0.title)
                }),
        ]
    }

    public func request(
        _ candidate: EntityCandidate, settings: AttentionSettings, options: [JevOption]
    ) -> JevRequest {
        var fields = context(settings)
        fields["name"] = candidate.name
        fields["type"] = candidate.isWebsite ? "website" : "macOS application"
        fields["identifier"] = candidate.identifier
        fields["window_titles"] = candidate.titles.map { JevText.compact($0, limit: 160) }
            .joined(separator: "\n")
        fields["usage"] = candidate.usage
        if !candidate.paths.isEmpty { fields["pages"] = candidate.paths.joined(separator: "\n") }
        if let about = candidate.about {
            fields["description"] = JevText.compact(about, limit: 300)
        }
        return JevRequest(
            state: .fields(fields),
            questions: questions(
                "time spent in the `type` called `name` (`identifier`), judging by its `description`, `window_titles`, `pages` and `usage`",
                settings: settings, options: options))
    }

    public func request(
        _ candidate: TitleCandidate, settings: AttentionSettings, options: [JevOption]
    ) -> JevRequest {
        var fields = context(settings)
        fields["site"] = "\(candidate.siteName) (\(candidate.site))"
        fields["title"] = JevText.compact(candidate.title, limit: 200)
        return JevRequest(
            state: .fields(fields),
            questions: questions(
                "reading or watching the page `title` on `site`", settings: settings,
                options: options))
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
                let decision = try? await decider.decide(
                    request(candidate, settings: settings, options: options),
                    purpose: Self.purpose)
            else { break }
            next.entities[candidate.key] = self.decision(
                decision, threshold: Self.entityThreshold, valid: valid, now: now)
            report.entities += 1
        }
        for candidate in titles {
            guard !Task.isCancelled,
                let decision = try? await decider.decide(
                    request(candidate, settings: settings, options: options),
                    purpose: Self.purpose)
            else { break }
            next.titles[candidate.key] = self.decision(
                decision, threshold: Self.titleThreshold, valid: valid, now: now)
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
        _ decision: JevDecision, threshold: Double, valid: Set<String>, now: Date
    ) -> AttentionJevDecision {
        let category = decision.answer(Self.question)
        let probability = category?.chosenProbability ?? 0
        guard let choice = category?.choice, valid.contains(choice), probability >= threshold
        else {
            return AttentionJevDecision(
                categoryID: AttentionJevDecision.none, confidence: probability, decidedAt: now)
        }
        let productivity = decision.answer(Self.productivityQuestion).flatMap { answer in
            (answer.chosenProbability ?? 0) >= Self.axisThreshold
                ? answer.choice.flatMap(AttentionProductivity.init(identifier:))
                : nil
        }
        let sphere = decision.answer(Self.sphereQuestion).flatMap { answer in
            (answer.chosenProbability ?? 0) >= Self.axisThreshold
                ? answer.choice.flatMap(AttentionSphere.init(rawValue:)) : nil
        }
        return AttentionJevDecision(
            categoryID: choice, confidence: probability, decidedAt: now,
            productivity: productivity, sphere: sphere)
    }
}
