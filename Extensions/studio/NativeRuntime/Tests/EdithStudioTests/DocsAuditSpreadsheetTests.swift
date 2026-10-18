import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct DocsAuditSpreadsheetTests {
    typealias F = DocsAuditFixtures

    static func book(at url: URL) throws {
        let c = F.cellXML
        let sales = F.sheetXML(
            [
                [
                    c("A1", "0", "s", nil, nil), c("B1", "1", "s", nil, nil),
                    c("C1", "2", "s", nil, nil), c("D1", "3", "s", nil, nil),
                    c("E1", "4", "s", nil, nil),
                ],
                [
                    c("A2", "45000", nil, 1, nil), c("B2", "0.125", nil, 2, nil),
                    c("C2", "0.5", nil, 3, nil), c("D2", "1234.5", nil, 4, nil),
                    c("E2", "2469", nil, 8, "D2*2"),
                ],
                [
                    c("A3", "45292", nil, 5, nil), c("B3", "0.0625", nil, 10, nil),
                    c("C3", "99.99", nil, 6, nil), c("D3", "0.0208333333333333", nil, 7, nil),
                    c("E3", "Done", "str", nil, "IF(1,\"Done\",\"\")"),
                ],
                [
                    c("A4", "45000.75", nil, 11, nil), c("B4", "1234567", nil, 9, nil),
                    c("C4", "#DIV/0!", "e", nil, "1/0"),
                    c("D4", "Line_x000D_ one", "inlineStr", nil, nil),
                    c("E4", "1", "b", nil, nil),
                ],
                [c("A5", "-1234.5", nil, 4, nil), c("B5", "0.3333333333333", nil, nil, nil)],
            ], merges: ["A6:C6"])
        let hidden = F.sheetXML([[c("A1", "Secret lookup", "inlineStr", nil, nil)]])
        try F.excelWorkbook(
            at: url,
            sheets: [("Sales", sales, nil), ("Lookup", hidden, "hidden")],
            shared: ["Date", "Share", "Pct", "Price", "Total"])
    }

    @Test func excelNumberFormatsFormulasAndHiddenSheets() async throws {
        let space = try Workspace()
        let url = space.url("book.xlsx")
        try Self.book(at: url)
        let original = try Data(contentsOf: url)
        let sheets = try SpreadsheetReader.read(url)
        #expect(sheets.map(\.name) == ["Sales"])
        #expect(
            sheets.first?.rows == [
                ["Date", "Share", "Pct", "Price", "Total"],
                ["2023-03-15", "13%", "50.00%", "$1,234.50", "2,469.00"],
                ["2024-01-01", "6.3%", "€99.99", "0:30", "Done"],
                ["2023-03-15 18:00", "1,234,567", "#DIV/0!", "Line one", "TRUE"],
                ["-$1,234.50", "0.3333333333"],
            ])

        let pdf = Fixtures.text(of: try await space.run("document.excel-to-pdf", [url]).url())
        for value in ["13%", "$1,234.50", "€99.99", "0:30", "2023-03-15 18:00", "Line one"] {
            #expect(pdf.contains(value), "\(value) missing from the PDF")
        }
        let secret = pdf.contains("Secret lookup")
        #expect(secret == false)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(markdown.contains("| Date | Share | Pct | Price | Total |"))
        #expect(markdown.contains("| 2024-01-01 | 6.3% | €99.99 | 0:30 | Done |"))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func formatEngineMatchesExcel() {
        let cases: [(Double, String, String)] = [
            (0.125, "0%", "13%"), (0.5, "0.00%", "50.00%"), (1234.5, "\"$\"#,##0.00", "$1,234.50"),
            (-1234.5, "#,##0.00;(#,##0.00)", "(1,234.50)"), (-3, "0", "-3"),
            (1_500_000, "#,##0,,\"M\"", "2M"), (0.000123, "0.00E+00", "1.23E-04"),
            (1.005, "0.00", "1.01"), (0, "#,##0;(#,##0);\"-\"", "-"), (0.5, "#.00", ".50"),
            (45000, "mmm d, yyyy", "Mar 15, 2023"), (45000, "dddd", "Wednesday"),
            (45000.5, "h:mm AM/PM", "12:00 PM"), (1.5, "[h]:mm", "36:00"),
            (45000.25, "yyyy-mm-dd hh:mm:ss", "2023-03-15 06:00:00"), (1.25, "# ?/?", "1 1/4"),
            (1234.5678, "General", "1234.5678"), (0.1 + 0.2, "General", "0.3"),
            (99.99, "[$€-407]#,##0.00", "€99.99"), (42, "@", "42"),
        ]
        for (value, code, expected) in cases {
            #expect(SpreadsheetFormat.display(value, code: code) == expected, "\(code) of \(value)")
        }
        #expect(
            SpreadsheetFormat.display(43538, code: "yyyy-mm-dd", date1904: true) == "2023-03-15")
    }

    @Test func wideSheetsAndLongCellsNeverLoseText() async throws {
        let space = try Workspace()
        let url = space.url("wide.xlsx")
        var rows = [(1...40).map { "Header \($0)" }]
        for row in 1...30 {
            rows.append((1...40).map { "R\(row)C\($0) value" })
        }
        rows.append(["Notes", String(repeating: "A long remark that wraps. ", count: 40) + "END"])
        try XLSXWriter.write([XLSXWriter.Sheet(name: "Wide", rows: rows)], title: "Wide", to: url)
        let result = try await space.run("document.excel-to-pdf", [url])
        let text = Fixtures.text(of: try result.url()).replacingOccurrences(of: "\n", with: " ")
        let missing = rows.flatMap { $0 }.filter { !$0.hasPrefix("A long") && !text.contains($0) }
        #expect(missing.isEmpty, "missing cells: \(missing.prefix(5))")
        #expect(text.contains("END"))
    }

    @Test func csvEncodingsAndDamagedWorkbooks() async throws {
        let space = try Workspace()
        let bom = space.url("bom.csv")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("name,city\nZoë,Köln\n".utf8)).write(to: bom)
        #expect(
            try SpreadsheetReader.read(bom).first?.rows == [["name", "city"], ["Zoë", "Köln"]])
        let latin = space.url("latin.csv")
        try Data([0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A]).write(to: latin)
        #expect(try SpreadsheetReader.read(latin).first?.rows == [["name"], ["Café"]])
        let multiline = space.url("notes.csv")
        try "item,note\nA,\"first line\nsecond line\"\n".write(
            to: multiline, atomically: true, encoding: .utf8)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [multiline]).url(),
            encoding: .utf8)
        #expect(markdown.contains("| A | first line<br>second line |"))

        for url in try F.damagedFiles(named: "sheet", ext: "xlsx", in: space) {
            let original = try Data(contentsOf: url)
            do {
                _ = try await space.run("document.to-pdf", [url])
                Issue.record("\(url.lastPathComponent) converted")
            } catch let error as StudioError {
                #expect(error.localizedDescription.contains(url.lastPathComponent))
                if url.lastPathComponent.contains("locked") {
                    #expect(error.localizedDescription.contains("password"))
                }
            }
            #expect(try Data(contentsOf: url) == original)
        }
    }
}
