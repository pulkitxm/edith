import Foundation

public enum StudioPageSelection {
    public static func groups(_ raw: String, pageCount: Int) throws -> [[Int]] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard pageCount > 0 else { throw StudioError.nothingToDo("The document has no pages.") }
        if text.isEmpty || text == "all" { return [Array(0..<pageCount)] }
        var groups: [[Int]] = []
        for token in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = token.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            groups.append(try indices(of: part, pageCount: pageCount))
        }
        guard !groups.isEmpty else {
            throw StudioError.invalidOption("pages", "no pages were selected")
        }
        return groups
    }

    public static func pages(_ raw: String, pageCount: Int) throws -> [Int] {
        var seen = Set<Int>()
        var ordered: [Int] = []
        for page in try groups(raw, pageCount: pageCount).joined() where seen.insert(page).inserted
        {
            ordered.append(page)
        }
        return ordered
    }

    public static func sortedPages(_ raw: String, pageCount: Int) throws -> [Int] {
        try pages(raw, pageCount: pageCount).sorted()
    }

    private static func indices(of part: String, pageCount: Int) throws -> [Int] {
        switch part {
        case "all": return Array(0..<pageCount)
        case "odd": return stride(from: 0, to: pageCount, by: 2).map { $0 }
        case "even": return stride(from: 1, to: pageCount, by: 2).map { $0 }
        case "first": return [0]
        case "last": return [pageCount - 1]
        default: break
        }
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func number(_ text: String, empty: Int) throws -> Int {
            if text.isEmpty { return empty }
            if text == "last" || text == "end" { return pageCount }
            guard let value = Int(text), value >= 1 else {
                throw StudioError.invalidOption("pages", "\(part) is not a page number")
            }
            guard value <= pageCount else {
                throw StudioError.invalidOption(
                    "pages", "page \(value) is past the last page (\(pageCount))")
            }
            return value
        }
        switch bounds.count {
        case 1:
            return [try number(bounds[0], empty: 1) - 1]
        case 2:
            let start = try number(bounds[0], empty: 1)
            let end = try number(bounds[1], empty: pageCount)
            if start <= end { return Array((start - 1)...(end - 1)) }
            return Array(((end - 1)...(start - 1)).reversed())
        default:
            throw StudioError.invalidOption("pages", "\(part) is not a page range")
        }
    }

    public static func label(for group: [Int]) -> String {
        guard let first = group.first, let last = group.last else { return "" }
        if group.count == 1 { return "page-\(first + 1)" }
        let contiguous = zip(group, group.dropFirst()).allSatisfy { $1 == $0 + 1 }
        return contiguous ? "pages-\(first + 1)-\(last + 1)" : "pages-\(first + 1)-etc"
    }
}
