import AVKit
import AppKit
import EdithKit
import Highlighter
import Observation
import PDFKit
import Quartz
import SwiftUI

@MainActor
@Observable
final class FilePreviewModel {
    enum Content: Equatable {
        case empty
        case loading
        case text(String, language: String?, truncated: Bool)
        case image(NSImage)
        case pdf(URL)
        case media(URL)
        case quickLook(URL)
        case unsupported(URL?, reason: String)
        case failed(String)
    }

    private(set) var content = Content.empty
    private var task: Task<Void, Never>?

    static let textPreviewLimit = RemoteFileOperationExecution.previewLimit

    func load(entry: RemoteFileEntry?, session: MachineSession) {
        task?.cancel()
        guard let entry, !entry.isDirectory else {
            content = .empty
            return
        }
        content = .loading
        task = Task { [weak self] in
            guard let self else { return }
            let kind = resolvedKind(for: entry)
            if kind == .text {
                await loadText(entry: entry, session: session)
                return
            }
            guard let url = await materialize(entry: entry, session: session) else { return }
            guard !Task.isCancelled else { return }
            switch kind {
            case .image:
                if let image = NSImage(contentsOf: url) {
                    content = .image(image)
                } else {
                    content = .unsupported(url, reason: "This image could not be read.")
                }
            case .pdf:
                content = .pdf(url)
            case .media:
                let asset = AVURLAsset(url: url)
                let playable = (try? await asset.load(.isPlayable)) ?? false
                guard !Task.isCancelled else { return }
                content =
                    playable
                    ? .media(url)
                    : .unsupported(url, reason: "macOS cannot play this format natively.")
            case .unsupported:
                content = .unsupported(
                    url, reason: "macOS cannot play this format natively. Open it in another app.")
            default:
                content = .quickLook(url)
            }
            RemoteFileOperationExecution.sweepCache()
        }
    }

    private func resolvedKind(for entry: RemoteFileEntry) -> FilePreviewKind {
        let byExtension = FilePreviewKind.kind(forExtension: entry.fileExtension)
        if byExtension == .quickLook, FilePreviewKind.isPlainTextName(entry.name) {
            return .text
        }
        return byExtension
    }

    private func loadText(entry: RemoteFileEntry, session: MachineSession) async {
        if session.isLocal {
            guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: entry.path))
            else {
                content = .failed("Could not read this file.")
                return
            }
            let data = handle.readData(ofLength: Self.textPreviewLimit + 1)
            try? handle.close()
            let preview = RemoteFileOperationExecution.textPreview(data)
            content = .text(
                preview.text, language: entry.fileExtension, truncated: preview.truncated)
            return
        }
        let command = RemoteFileOperationExecution.previewCommand(path: entry.path)
        let result = await session.runCommand(command, timeout: 45)
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(text):
            let preview = RemoteFileOperationExecution.textPreview(text)
            content = .text(
                preview.text, language: entry.fileExtension,
                truncated: preview.truncated || entry.sizeBytes > Int64(Self.textPreviewLimit))
        case let .failure(error):
            content = .failed(error.localizedDescription)
        }
    }

    private func materialize(entry: RemoteFileEntry, session: MachineSession) async -> URL? {
        do {
            return try await RemoteFileOperationExecution.materialize(
                entry, machineID: session.machine.id, isLocal: session.isLocal
            ) { remotePath, destination in
                guard let connection = session.connectionRef else {
                    throw FinderTransferError.notConnected
                }
                try await connection.download(remotePath: remotePath, to: destination)
            }
        } catch {
            guard !Task.isCancelled else { return nil }
            content = .failed(error.localizedDescription)
            return nil
        }
    }
}

struct FilePreviewPane: View {
    let entry: RemoteFileEntry?
    let session: MachineSession
    @State private var model = FilePreviewModel()
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
        }
        .background(DashSkin.paper2(dark))
        .onChange(of: entry?.id) { _, _ in
            model.load(entry: entry, session: session)
        }
        .onAppear { model.load(entry: entry, session: session) }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            if let entry {
                Image(nsImage: FileIcons.icon(for: entry))
                    .resizable()
                    .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name)
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    Text(ByteFormatter.string(entry.sizeBytes))
                        .font(DashSkin.mono(10))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            } else {
                Text("Preview")
                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(10))
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .empty:
            placeholder("Select a file to preview it.", symbol: "doc.text.magnifyingglass")
        case .loading:
            VStack(spacing: UIScale.pt(10)) {
                ProgressView()
                Text("Loading preview…")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .text(text, language, truncated):
            CodePreview(text: text, language: language, truncated: truncated, dark: dark)
        case let .image(image):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(UIScale.pt(12))
            }
        case let .pdf(url):
            PDFPreview(url: url)
        case let .quickLook(url):
            QuickLookPreview(url: url)
        case let .media(url):
            VideoPlayer(player: AVPlayer(url: url))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .unsupported(url, reason):
            VStack(spacing: UIScale.pt(12)) {
                Image(systemName: "play.slash")
                    .font(.system(size: UIScale.pt(28)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(reason)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .multilineTextAlignment(.center)
                if let url {
                    Button("Open in default app") {
                        RemoteFileOperationExecution.present([url], action: .open) { urls, _ in
                            NSWorkspace.shared.open(urls[0])
                        }
                    }
                    .pointerCursor()
                }
            }
            .padding(UIScale.pt(20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            placeholder(message, symbol: "exclamationmark.triangle")
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: UIScale.pt(10)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(26)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(text)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .multilineTextAlignment(.center)
        }
        .padding(UIScale.pt(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CodePreview: View {
    let text: String
    let language: String?
    let truncated: Bool
    let dark: Bool
    @State private var highlighted: NSAttributedString?

    var body: some View {
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
            HighlightedTextView(attributed: highlighted, plain: text, dark: dark)
        }
        .task(id: highlightKey) {
            highlighted = await SyntaxHighlighting.shared.highlight(
                text: text, language: language, dark: dark)
        }
    }

    private var highlightKey: String {
        "\(language ?? "")-\(dark)-\(text.count)"
    }
}

actor SyntaxHighlighting {
    static let shared = SyntaxHighlighting()

    private var highlighter: Highlighter?
    private var currentTheme: String?

    func highlight(text: String, language: String?, dark: Bool) -> NSAttributedString? {
        guard text.count < 400_000 else { return nil }
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

private struct HighlightedTextView: NSViewRepresentable {
    let attributed: NSAttributedString?
    let plain: String
    let dark: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
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
        if let attributed {
            textView.textStorage?.setAttributedString(attributed)
        } else {
            textView.string = plain
            textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            textView.textColor = dark ? .white : .textColor
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
