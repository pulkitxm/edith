import Foundation

struct AttentionRuleDocument: Codable {
    var categories: [AttentionCategory]
    var rules: [AttentionIdentityRule]

    func applying(to original: AttentionSettings) throws -> AttentionSettings {
        var settings = original
        guard Set(categories.map(\.id)).count == categories.count,
            Set(rules.map(\.id)).count == rules.count
        else { throw AttentionServiceError("Category and rule IDs must be unique") }
        for category in categories {
            guard !category.id.isEmpty, !category.name.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw AttentionServiceError("Categories need an ID and a name") }
            if let index = settings.categories.firstIndex(where: { $0.id == category.id }) {
                settings.categories[index] = category
            } else {
                settings.categories.append(category)
            }
        }
        for rule in rules {
            guard !rule.id.isEmpty, !rule.name.trimmingCharacters(in: .whitespaces).isEmpty,
                !rule.isEmpty, settings.categories.contains(where: { $0.id == rule.categoryID })
            else {
                throw AttentionServiceError(
                    "Rules need an ID, name, known category and match criteria")
            }
            if let index = settings.rules.firstIndex(where: { $0.id == rule.id }) {
                settings.rules[index] = rule
            } else {
                settings.rules.append(rule)
            }
        }
        return settings
    }
}
