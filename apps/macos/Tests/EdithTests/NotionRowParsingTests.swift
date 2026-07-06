import Foundation
import Testing

@testable import EdithKit

@Suite struct NotionRowParsingTests {
    private func page(
        title: String, tags: [String], status: String?, project: String?, completed: String?
    ) -> [String: Any] {
        var props: [String: Any] = [
            "Task": ["type": "title", "title": [["plain_text": title]]],
            "Tags": ["type": "multi_select", "multi_select": tags.map { ["name": $0] }],
        ]
        if let status { props["Status"] = ["type": "select", "select": ["name": status]] }
        if let project {
            props["Project"] = ["type": "rich_text", "rich_text": [["plain_text": project]]]
        }
        if let completed {
            props["Completed"] = ["type": "date", "date": ["start": completed]]
        }
        return ["properties": props]
    }

    private func response(_ pages: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["results": pages])
    }

    @Test func extractsTitleTagsAndDate() {
        let data = response([
            page(
                title: "Fix dashboard bug", tags: ["work"], status: "Done", project: "edith",
                completed: "2024-01-09T10:00:00.000Z")
        ])
        let rows = NotionRowParsing.parse(data, tagsProperty: "Tags", dateProperty: "Completed")
        #expect(rows.count == 1)
        #expect(rows[0].title == "Fix dashboard bug")
        #expect(rows[0].tags == ["work"])
        #expect(rows[0].contextLine == "Fix dashboard bug — Project: edith — Status: Done")
        #expect(rows[0].date != nil)
    }

    @Test func missingTitleFallsBackToUntitled() {
        let data = response([page(title: "", tags: [], status: nil, project: nil, completed: nil)])
        let rows = NotionRowParsing.parse(data, tagsProperty: "Tags", dateProperty: "Completed")
        #expect(rows[0].title == "Untitled")
    }

    @Test func linesInRangeIncludesOnlyMatchingDates() {
        let data = response([
            page(
                title: "In range", tags: ["work"], status: nil, project: nil,
                completed: "2024-01-09T10:00:00.000Z"),
            page(
                title: "Out of range", tags: ["work"], status: nil, project: nil,
                completed: "2024-01-01T10:00:00.000Z"),
            page(title: "No date", tags: ["work"], status: nil, project: nil, completed: nil),
        ])
        let rows = NotionRowParsing.parse(data, tagsProperty: "Tags", dateProperty: "Completed")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let since = cal.date(from: DateComponents(year: 2024, month: 1, day: 9))!
        let until = cal.date(from: DateComponents(year: 2024, month: 1, day: 10))!
        let lines = NotionRowParsing.linesInRange(rows, since: since, until: until)
        #expect(lines.contains { $0.contains("In range") })
        #expect(lines.contains { $0.contains("No date") })
        #expect(!lines.contains { $0.contains("Out of range") })
    }
}
