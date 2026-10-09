import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

public struct CodePreview: View {
    let text: String
    let language: String?
    let truncated: Bool
    let dark: Bool
    @State private var highlighted: NSAttributedString?

    public init(text: String, language: String?, truncated: Bool, dark: Bool) {
        self.text = text
        self.language = language
        self.truncated = truncated
        self.dark = dark
    }

    public var body: some View {
        VStack(spacing: 0) {
            if truncated {
                Text("Showing the first 400 KB.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, UIScale.pt(14))
                    .padding(.vertical, UIScale.pt(6))
                    .background(DashSkin.gold.opacity(0.12))
            }
            HighlightedTextView(
                attributed: highlighted, plain: text, dark: dark, scale: UIScale.current)
        }
        .pageTask(id: highlightKey) {
            highlighted = await SyntaxHighlighting.shared.highlight(
                text: text, language: language, dark: dark)
        }
    }

    private var highlightKey: String {
        "\(language ?? "")-\(dark)-\(text)"
    }
}

actor SyntaxHighlighting {
    static let shared = SyntaxHighlighting()

    static let cacheLimit = 64
    static let cacheableBytes = 16_384

    private struct CacheKey: Hashable {
        let text: String
        let language: String?
        let dark: Bool
    }

    private var highlighter: Highlighter?
    private var currentTheme: String?
    private var cache: [CacheKey: NSAttributedString] = [:]
    private var cacheOrder: [CacheKey] = []

    func highlight(text: String, language: String?, dark: Bool) -> NSAttributedString? {
        guard !Task.isCancelled, text.utf8.count < 400_000 else { return nil }
        let key =
            text.utf8.count <= Self.cacheableBytes
            ? CacheKey(text: text, language: language, dark: dark) : nil
        if let key, let cached = cache[key] { return cached }
        let result = render(text: text, language: language, dark: dark)
        if let key, let result {
            if cacheOrder.count >= Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
            cache[key] = result
            cacheOrder.append(key)
        }
        return result
    }

    private func render(text: String, language: String?, dark: Bool) -> NSAttributedString? {
        let theme = dark ? "atom-one-dark" : "atom-one-light"
        if highlighter == nil {
            highlighter = Highlighter()
        }
        guard let highlighter else { return nil }
        if currentTheme != theme {
            highlighter.setTheme(theme)
            currentTheme = theme
        }
        let resolved = Self.languageName(for: language)
        return highlighter.highlight(text, as: resolved)
    }

    static func languageName(for ext: String?) -> String? {
        guard let ext, !ext.isEmpty else { return nil }
        let map: [String: String] = [
            "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
            "ts": "typescript", "tsx": "typescript", "py": "python", "rb": "ruby",
            "sh": "bash", "zsh": "bash", "bash": "bash", "yml": "yaml", "md": "markdown",
            "markdown": "markdown", "htm": "html", "rs": "rust", "kt": "kotlin",
            "kts": "kotlin", "h": "c", "hpp": "cpp", "cc": "cpp", "m": "objectivec",
            "mm": "objectivec", "conf": "ini", "cfg": "ini", "env": "ini", "toml": "ini",
            "service": "ini", "socket": "ini", "timer": "ini", "gitignore": "bash",
            "dockerfile": "dockerfile", "tf": "hcl", "jsonl": "json",
        ]
        return map[ext] ?? ext
    }
}

enum PreviewTextScale {
    static let body = 11.5
    static let inset = 10.0

    static func attributed(_ source: NSAttributedString, scale: Double) -> NSAttributedString {
        guard abs(scale - 1) > 0.001, source.length > 0 else { return source }
        let copy = NSMutableAttributedString(attributedString: source)
        copy.enumerateAttribute(.font, in: NSRange(location: 0, length: copy.length)) {
            value, range, _ in
            guard let font = value as? NSFont else { return }
            copy.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: range)
        }
        return copy
    }
}

private struct HighlightedTextView: NSViewRepresentable {
    let attributed: NSAttributedString?
    let plain: String
    let dark: Bool
    var scale = 1.0

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: PreviewTextScale.inset * scale, height: PreviewTextScale.inset * scale)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textContainerInset = NSSize(
            width: PreviewTextScale.inset * scale, height: PreviewTextScale.inset * scale)
        textView.font = .monospacedSystemFont(
            ofSize: PreviewTextScale.body * scale, weight: .regular)
        if let attributed {
            textView.textStorage?.setAttributedString(
                PreviewTextScale.attributed(attributed, scale: scale))
        } else {
            textView.string = plain
            textView.textColor = dark ? .white : .textColor
        }
    }
}
