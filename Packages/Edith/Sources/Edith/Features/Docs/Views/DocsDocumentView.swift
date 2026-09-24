import AppKit
import EdithKit
import SwiftUI

enum DocsLinkURL {
    static let scheme = "edith-docs"

    static func url(for link: DocsLink) -> URL? {
        switch link {
        case .external(let url): return url
        case .page(let path, let anchor):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "page"
            components.path = "/" + path
            components.fragment = anchor
            return components.url
        }
    }

    static func link(for url: URL) -> DocsLink {
        guard url.scheme == scheme else { return .external(url) }
        return .page(path: String(url.path.dropFirst()), anchor: url.fragment)
    }
}

enum DocsTypography {
    static let body = 13.5
    static let headings = [1: 26.0, 2: 19.0, 3: 15.5]

    static func codeFill(_ dark: Bool) -> Color {
        DashSkin.ink(dark).opacity(dark ? 0.1 : 0.06)
    }

    static func text(
        _ spans: [DocsSpan], size: Double, dark: Bool, weight: Font.Weight = .regular,
        codeFill: Bool = true
    ) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            let bold = span.style.contains(.strong) ? Font.Weight.semibold : weight
            var font: Font =
                span.style.contains(.code)
                ? .system(size: UIScale.pt(size * 0.9), weight: bold, design: .monospaced)
                : .system(size: UIScale.pt(size), weight: bold)
            if span.style.contains(.emphasis) { font = font.italic() }
            piece.font = font
            if span.style.contains(.code), codeFill { piece.backgroundColor = Self.codeFill(dark) }
            if span.style.contains(.strikethrough) { piece.strikethroughStyle = .single }
            if let link = span.link, let url = DocsLinkURL.url(for: link) {
                piece.link = url
                piece.foregroundColor = DashSkin.accent(dark)
                piece.underlineStyle = Text.LineStyle(
                    pattern: .solid, color: DashSkin.accent(dark).opacity(0.35))
            }
            result += piece
        }
        return result
    }

    static func highlighted(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        source.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: source.length)
        ) { value, range, _ in
            var piece = AttributedString(source.attributedSubstring(from: range).string)
            if let color = value as? NSColor { piece.foregroundColor = Color(nsColor: color) }
            result += piece
        }
        return result
    }

    static func language(_ language: String?, text: String) -> String? {
        switch language {
        case "text", "txt", "plain", "console": nil
        case nil: text.hasPrefix("ed ") || text.hasPrefix("$ ") ? "bash" : nil
        default: language
        }
    }
}

struct DocsBlockRow: Identifiable {
    let id: String
    let block: DocsBlock

    static func rows(_ blocks: [DocsBlock]) -> [DocsBlockRow] {
        blocks.enumerated().map { index, block in
            if case .heading(let heading) = block {
                return DocsBlockRow(id: heading.anchor, block: block)
            }
            return DocsBlockRow(id: "block-\(index)", block: block)
        }
    }
}

struct DocsBlockView: View {
    let block: DocsBlock
    let width: Double
    let dark: Bool
    var flashAnchor: String?
    var depth = 0

    var body: some View {
        switch block {
        case .heading(let heading):
            DocsHeadingView(heading: heading, dark: dark, flashing: flashAnchor == heading.anchor)
        case .paragraph(let spans):
            Text(DocsTypography.text(spans, size: DocsTypography.body, dark: dark))
                .foregroundStyle(DashSkin.ink(dark))
                .lineSpacing(UIScale.pt(3.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let text):
            DocsCodeBlock(language: language, text: text, dark: dark)
        case .list(let list):
            DocsListView(list: list, width: width, dark: dark, depth: depth)
        case .table(let table):
            DocsTableView(table: table, width: width, dark: dark)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DashSkin.lineStrong(dark))
                    .frame(width: UIScale.pt(3))
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    ForEach(DocsBlockRow.rows(blocks)) { row in
                        DocsBlockView(
                            block: row.block, width: width - UIScale.pt(15), dark: dark,
                            depth: depth)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle()
                .fill(DashSkin.line(dark))
                .frame(height: 1)
                .padding(.vertical, UIScale.pt(6))
        }
    }
}

private struct DocsHeadingView: View {
    let heading: DocsHeading
    let dark: Bool
    let flashing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text(
                DocsTypography.text(
                    heading.spans, size: DocsTypography.headings[heading.level] ?? 14,
                    dark: dark, weight: .semibold, codeFill: false)
            )
            .foregroundStyle(DashSkin.ink(dark))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(4))
            .background(
                DashSkin.accent(dark).opacity(flashing ? 0.18 : 0),
                in: RoundedRectangle(cornerRadius: UIScale.pt(7))
            )
            .padding(.horizontal, UIScale.pt(-8))
            if heading.level == 2 {
                Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
            }
        }
        .padding(.top, UIScale.pt(heading.level == 1 ? 0 : heading.level == 2 ? 18 : 8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.35), value: flashing)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct DocsListView: View {
    let list: DocsList
    let width: Double
    let dark: Bool
    let depth: Int

    private var markerWidth: Double { UIScale.pt(list.ordered ? 22 : 14) }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
                    Text(marker(index))
                        .font(.system(size: UIScale.pt(DocsTypography.body), weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: markerWidth, alignment: .trailing)
                    VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                        ForEach(DocsBlockRow.rows(item)) { row in
                            DocsBlockView(
                                block: row.block, width: width - markerWidth - UIScale.pt(6),
                                dark: dark, depth: depth + 1)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func marker(_ index: Int) -> String {
        guard !list.ordered else { return "\(list.start + index)." }
        return ["\u{2022}", "\u{25E6}", "\u{25AA}"][depth % 3]
    }
}

private struct DocsCodeBlock: View {
    let language: String?
    let text: String
    let dark: Bool
    @State private var highlighted: AttributedString?
    @State private var copied = false

    private var highlightLanguage: String? { DocsTypography.language(language, text: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: UIScale.pt(8)) {
                Text(language ?? "")
                    .font(DashSkin.mono(10.5, weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer(minLength: 0)
                Button(action: copy) {
                    Label(
                        copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(copied ? DashSkin.ok : DashSkin.inkSoft(dark))
                }
                .buttonStyle(.edith(.borderless))
                .help("Copy this code")
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(6))
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
            ScrollView(.horizontal) {
                Text(highlighted ?? AttributedString(text))
                    .font(DashSkin.mono(12))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineSpacing(UIScale.pt(3))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, UIScale.pt(12))
                    .padding(.vertical, UIScale.pt(10))
            }
            .scrollIndicators(.automatic)
        }
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(DashSkin.line(dark))
        )
        .task(id: "\(dark)-\(text.hashValue)") {
            guard let language = highlightLanguage,
                let result = await SyntaxHighlighting.shared.highlight(
                    text: text, language: language, dark: dark)
            else { return }
            highlighted = DocsTypography.highlighted(result)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

enum DocsTableLayout {
    static let padding = 10.0
    static let longestWord = 220.0

    static func widths(_ table: DocsTable, available: Double) -> [Double] {
        let columns = table.header.count
        var minimum = Array(repeating: 0.0, count: columns)
        var natural = Array(repeating: 0.0, count: columns)
        for (index, row) in ([table.header] + table.rows).enumerated() {
            for (column, cell) in row.enumerated() where column < columns {
                let (word, line) = measure(cell, bold: index == 0)
                minimum[column] = max(minimum[column], min(word, UIScale.pt(longestWord)))
                natural[column] = max(natural[column], line)
            }
        }
        let inset = UIScale.pt(padding) * 2
        minimum = minimum.map { $0 + inset }
        natural = natural.map { $0 + inset }
        if natural.reduce(0, +) <= available { return natural }
        let floor = minimum.reduce(0, +)
        guard floor < available else { return minimum }
        let slack = zip(natural, minimum).map { max(0, $0 - $1) }
        let totalSlack = max(1, slack.reduce(0, +))
        return zip(minimum, slack).map { $0 + (available - floor) * $1 / totalSlack }
    }

    static func measure(_ spans: [DocsSpan], bold: Bool) -> (word: Double, line: Double) {
        var word = 0.0
        var line = 0.0
        for span in spans {
            let size = UIScale.pt(span.style.contains(.code) ? 12.5 * 0.9 : 12.5)
            let weight: NSFont.Weight = bold || span.style.contains(.strong) ? .semibold : .regular
            let font =
                span.style.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            line += (span.text as NSString).size(withAttributes: attributes).width
            for piece in span.text.split(separator: " ") {
                word = max(word, (String(piece) as NSString).size(withAttributes: attributes).width)
            }
        }
        return (ceil(word) + 2, ceil(line) + 2)
    }
}

private struct DocsTableView: View {
    let table: DocsTable
    let width: Double
    let dark: Bool

    var body: some View {
        let widths = DocsTableLayout.widths(table, available: width)
        let total = widths.reduce(0, +)
        if total > width + 1 {
            ScrollView(.horizontal) { grid(widths) }
                .scrollIndicators(.automatic)
        } else {
            grid(widths)
        }
    }

    private func grid(_ widths: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(table.header, widths: widths, header: true)
                .background(DashSkin.ink(dark).opacity(dark ? 0.07 : 0.04))
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
                row(cells, widths: widths, header: false)
                    .background(DashSkin.ink(dark).opacity(index.isMultiple(of: 2) ? 0 : 0.018))
            }
        }
        .frame(width: widths.reduce(0, +), alignment: .leading)
        .background(DashSkin.paper2(dark))
        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(9)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(9)).strokeBorder(DashSkin.line(dark))
        )
    }

    private func row(_ cells: [[DocsSpan]], widths: [Double], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, columnWidth in
                let alignment =
                    table.alignments.indices.contains(column)
                    ? table.alignments[column] : .leading
                Text(
                    DocsTypography.text(
                        column < cells.count ? cells[column] : [], size: 12.5, dark: dark,
                        weight: header ? .semibold : .regular)
                )
                .foregroundStyle(header ? DashSkin.ink(dark) : DashSkin.ink(dark).opacity(0.92))
                .multilineTextAlignment(
                    alignment == .trailing ? .trailing : alignment == .center ? .center : .leading
                )
                .lineSpacing(UIScale.pt(2))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UIScale.pt(DocsTableLayout.padding))
                .padding(.vertical, UIScale.pt(header ? 7 : 8))
                .frame(
                    width: columnWidth,
                    alignment: alignment == .trailing
                        ? .trailing : alignment == .center ? .center : .leading
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) {
                    if column > 0 { Rectangle().fill(DashSkin.line(dark)).frame(width: 1) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
