import Testing

@testable import AttentionNative
@MainActor
struct AttentionBreakdownPresentationTests {
    @Test func repeatedAndEmptyNamesHaveNoSubtitle() {
        for label in ["Edith", "Netflix", "YouTube: Comedy"] {
            let row = AttentionBreakdownItem(
                key: label, label: label, duration: 60, categories: [:],
                names: [label, "", "  ", label.uppercased()], interactions: 0)
            #expect(row.subtitle == nil)
        }
    }

    @Test func distinctNamesAndEntityContextAreShownOnce() {
        let entity = AttentionEntity(
            id: "site", name: "Netflix",
            category: AttentionCategory(id: "entertainment", name: "Entertainment"),
            source: .browser,
            duration: 60, domain: "netflix.com")
        let row = AttentionBreakdownItem(
            key: "Netflix", label: "Netflix", duration: 60, categories: [:],
            names: ["Netflix", "Comedy", "Comedy"], entity: entity, interactions: 0)
        #expect(row.subtitle?.hasPrefix("Comedy, netflix.com") == true)
    }
}
