import EdithKit
import SwiftUI

struct MarkdownBody: View {
    let text: String
    let dark: Bool
    var size: CGFloat = 12.5
    var bodyInk = false

    private enum Block {
        case heading(Int, String)
        case items([(String, String)])
        case code(String)
        case paragraph(String)
    }

    private var bodyColor: Color {
        bodyInk ? DashSkin.ink(dark) : DashSkin.inkSoft(dark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    private static func listMarker(_ line: String) -> (String, String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)))
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var items: [(String, String)] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flush() {
            if !items.isEmpty {
                result.append(.items(items))
                items = []
            }
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = String(rawLine.trimmingCharacters(in: .whitespaces))
            if inCode {
                if rawLine.hasPrefix("```") {
                    result.append(.code(code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    code.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                inCode = true
            } else if line.hasPrefix("### ") {
                flush()
                result.append(.heading(3, String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flush()
                result.append(.heading(2, String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush()
                result.append(.heading(1, String(line.dropFirst(2))))
            } else if let (marker, item) = Self.listMarker(line) {
                if !paragraph.isEmpty {
                    result.append(.paragraph(paragraph.joined(separator: " ")))
                    paragraph = []
                }
                items.append((marker, item))
            } else if line.isEmpty {
                flush()
            } else {
                if !items.isEmpty {
                    result.append(.items(items))
                    items = []
                }
                paragraph.append(line)
            }
        }
        if inCode, !code.isEmpty {
            result.append(.code(code.joined(separator: "\n")))
        }
        flush()
        return result
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case let .heading(level, title):
            Text(inline(title))
                .font(
                    DashSkin.serif(
                        UIScale.pt(level == 1 ? size + 4.5 : level == 2 ? size + 2.5 : size + 1),
                        weight: .semibold)
                )
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.top, UIScale.pt(3))
        case let .items(items):
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(6)) {
                        Text(item.0)
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .monospacedDigit()
                        Text(inline(item.1))
                            .foregroundStyle(bodyColor)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: UIScale.pt(size)))
                }
            }
        case let .code(source):
            Text(source)
                .font(DashSkin.mono(UIScale.pt(size - 1.5)))
                .foregroundStyle(bodyColor)
                .textSelection(.enabled)
                .padding(UIScale.pt(8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
        case let .paragraph(content):
            Text(inline(content))
                .font(.system(size: UIScale.pt(size)))
                .foregroundStyle(bodyColor)
                .textSelection(.enabled)
        }
    }

    private func inline(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}
