import Foundation
import Markdown

public enum DocsParser {
    public static func page(path: String, markdown: String) -> DocsPage {
        let context = Context(path: path)
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        let blocks = context.blocks(document.children)
        return DocsPage(path: path, markdown: markdown, blocks: blocks, headings: context.headings)
    }

    private final class Context {
        let path: String
        var headings: [DocsHeading] = []
        var usedAnchors: [String: Int] = [:]

        init(path: String) {
            self.path = path
        }

        func blocks(_ children: MarkupChildren) -> [DocsBlock] {
            var blocks: [DocsBlock] = []
            for child in children {
                if let block = block(child) { blocks.append(block) }
            }
            return blocks
        }

        func block(_ markup: Markup) -> DocsBlock? {
            switch markup {
            case let heading as Heading:
                let spans = inline(heading)
                let entry = DocsHeading(
                    level: heading.level, spans: spans, anchor: anchor(DocsSpan.plain(spans)))
                headings.append(entry)
                return .heading(entry)
            case let paragraph as Paragraph:
                return .paragraph(inline(paragraph))
            case let code as CodeBlock:
                let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased()
                var text = code.code
                while text.hasSuffix("\n") { text.removeLast() }
                return .code(language: language?.isEmpty == false ? language : nil, text: text)
            case let list as UnorderedList:
                return .list(DocsList(ordered: false, start: 1, items: items(list.children)))
            case let list as OrderedList:
                return .list(
                    DocsList(
                        ordered: true, start: Int(list.startIndex), items: items(list.children)))
            case let table as Markdown.Table:
                return .table(self.table(table))
            case let quote as BlockQuote:
                return .quote(blocks(quote.children))
            case is ThematicBreak:
                return .rule
            case let html as HTMLBlock:
                return .paragraph([DocsSpan(html.rawHTML)])
            default:
                return nil
            }
        }

        func items(_ children: MarkupChildren) -> [[DocsBlock]] {
            var items: [[DocsBlock]] = []
            for child in children {
                if let item = child as? ListItem { items.append(blocks(item.children)) }
            }
            return items
        }

        func table(_ table: Markdown.Table) -> DocsTable {
            var header: [[DocsSpan]] = []
            for cell in table.head.cells { header.append(inline(cell)) }
            var rows: [[[DocsSpan]]] = []
            for row in table.body.rows {
                var cells: [[DocsSpan]] = []
                for cell in row.cells { cells.append(inline(cell)) }
                while cells.count < header.count { cells.append([]) }
                rows.append(cells)
            }
            let alignments = table.columnAlignments.map { alignment -> DocsAlignment in
                switch alignment {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            return DocsTable(
                alignments: header.indices.map {
                    $0 < alignments.count ? alignments[$0] : .leading
                },
                header: header, rows: rows)
        }

        func anchor(_ text: String) -> String {
            let base = DocsPath.slug(text)
            let count = usedAnchors[base, default: 0]
            usedAnchors[base] = count + 1
            return count == 0 ? base : "\(base)-\(count)"
        }

        func inline(
            _ markup: Markup, style: DocsSpan.Style = [], link: DocsLink? = nil
        ) -> [DocsSpan] {
            var spans: [DocsSpan] = []
            func add(_ text: String, _ extra: DocsSpan.Style = []) {
                let merged = style.union(extra)
                if let last = spans.last, last.style == merged, last.link == link {
                    spans[spans.count - 1].text += text
                } else {
                    spans.append(DocsSpan(text, style: merged, link: link))
                }
            }
            for child in markup.children {
                switch child {
                case let text as Markdown.Text: add(text.string)
                case let code as InlineCode: add(code.code, .code)
                case is SoftBreak: add(" ")
                case is LineBreak: add("\n")
                case let html as InlineHTML: add(html.rawHTML)
                case is Strong: spans += inline(child, style: style.union(.strong), link: link)
                case is Emphasis: spans += inline(child, style: style.union(.emphasis), link: link)
                case is Strikethrough:
                    spans += inline(child, style: style.union(.strikethrough), link: link)
                case let anchor as Markdown.Link:
                    spans += inline(anchor, style: style, link: resolve(anchor.destination) ?? link)
                default: spans += inline(child, style: style, link: link)
                }
            }
            return spans
        }

        func resolve(_ destination: String?) -> DocsLink? {
            guard let destination, !destination.isEmpty else { return nil }
            if destination.hasPrefix("#") {
                return .page(path: path, anchor: String(destination.dropFirst()))
            }
            if let url = URL(string: destination), url.scheme?.isEmpty == false {
                return .external(url)
            }
            let parts = destination.split(separator: "#", maxSplits: 1).map(String.init)
            return .page(
                path: DocsPath.resolve(parts.first ?? "", from: path),
                anchor: parts.count > 1 ? parts[1] : nil)
        }
    }
}
