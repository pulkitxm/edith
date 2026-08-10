import AppKit
import EdithKit
import SwiftUI

struct LogPalette: Equatable {
    var text: NSColor
    var stderr: NSColor
    var timestamp: NSColor
    var background: NSColor
}

struct LogDocument: Equatable {
    var lines: [DockerLogLine]
    var showTimestamps: Bool
    var wraps: Bool
    var fontSize: Double
}

struct LogPresentation: Equatable {
    var showTimestamps: Bool
    var wraps: Bool
    var fontSize: Double
    var palette: LogPalette
}

final class LogTextViewController: NSViewController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var renderedIDs: [Int] = []
    private var renderedLengths: [Int] = []
    private var renderedPresentation: LogPresentation?

    var onScrolledAwayFromBottom: ((Bool) -> Void)?

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        view = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    @objc private func didScroll() {
        onScrolledAwayFromBottom?(!isPinnedToBottom)
    }

    private var isPinnedToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.bounds.height - 24
    }

    func apply(_ document: LogDocument, palette: LogPalette, follow: Bool) {
        let presentation = LogPresentation(
            showTimestamps: document.showTimestamps, wraps: document.wraps,
            fontSize: document.fontSize, palette: palette)
        let wasPinned = isPinnedToBottom

        if presentation != renderedPresentation {
            renderedPresentation = presentation
            configureWrapping(document.wraps)
            textView.backgroundColor = palette.background
            scrollView.backgroundColor = palette.background
            rebuild(document, palette: palette)
        } else if let appended = appendedSuffix(of: document.lines) {
            guard !appended.dropped.isEmpty || !appended.added.isEmpty else { return }
            mutate(
                dropping: appended.dropped, adding: appended.added, palette: palette,
                document: document)
        } else {
            rebuild(document, palette: palette)
        }

        if follow, wasPinned { textView.scrollToEndOfDocument(nil) }
    }

    private func appendedSuffix(
        of lines: [DockerLogLine]
    ) -> (dropped: [Int], added: ArraySlice<DockerLogLine>)? {
        guard let firstIncoming = lines.first else {
            return renderedIDs.isEmpty
                ? nil : (Array(0..<renderedIDs.count), lines[lines.startIndex..<lines.startIndex])
        }
        guard !renderedIDs.isEmpty else { return ([], lines[...]) }
        guard let pivot = renderedIDs.firstIndex(of: firstIncoming.id) else { return nil }
        let kept = renderedIDs.count - pivot
        guard lines.count >= kept else { return nil }
        for offset in 0..<kept where renderedIDs[pivot + offset] != lines[offset].id { return nil }
        return (Array(0..<pivot), lines[kept...])
    }

    private func attributed(
        _ line: DockerLogLine, palette: LogPalette, font: NSFont, showTimestamps: Bool
    ) -> NSAttributedString {
        let body = NSMutableAttributedString()
        if showTimestamps, let stamp = line.timestamp {
            body.append(
                NSAttributedString(
                    string: stamp + "  ",
                    attributes: [.font: font, .foregroundColor: palette.timestamp]))
        }
        body.append(
            NSAttributedString(
                string: line.text + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: line.isStderr ? palette.stderr : palette.text,
                ]))
        return body
    }

    private func font(_ size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func rebuild(_ document: LogDocument, palette: LogPalette) {
        let typeface = font(document.fontSize)
        let body = NSMutableAttributedString()
        var ids: [Int] = []
        var lengths: [Int] = []
        ids.reserveCapacity(document.lines.count)
        lengths.reserveCapacity(document.lines.count)
        for line in document.lines {
            let piece = attributed(
                line, palette: palette, font: typeface, showTimestamps: document.showTimestamps)
            body.append(piece)
            ids.append(line.id)
            lengths.append(piece.length)
        }
        textView.textStorage?.setAttributedString(body)
        textView.setSelectedRange(NSRange(location: body.length, length: 0))
        renderedIDs = ids
        renderedLengths = lengths
    }

    private func mutate(
        dropping dropped: [Int], adding added: ArraySlice<DockerLogLine>, palette: LogPalette,
        document: LogDocument
    ) {
        guard let storage = textView.textStorage else { return }
        let typeface = font(document.fontSize)
        storage.beginEditing()
        if !dropped.isEmpty {
            let droppedChars = dropped.reduce(0) { $0 + renderedLengths[$1] }
            if droppedChars > 0, droppedChars <= storage.length {
                storage.deleteCharacters(in: NSRange(location: 0, length: droppedChars))
            }
            renderedIDs.removeFirst(dropped.count)
            renderedLengths.removeFirst(dropped.count)
        }
        for line in added {
            let piece = attributed(
                line, palette: palette, font: typeface, showTimestamps: document.showTimestamps)
            storage.append(piece)
            renderedIDs.append(line.id)
            renderedLengths.append(piece.length)
        }
        storage.endEditing()
    }

    private func configureWrapping(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        if wraps {
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.containerSize = NSSize(
                width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = true
        }
    }

    var renderedText: String { textView.string }

    func scrollToEnd() {
        textView.scrollToEndOfDocument(nil)
    }
}

struct LogTextView: NSViewControllerRepresentable {
    let document: LogDocument
    let palette: LogPalette
    let follow: Bool
    var onScrolledAwayFromBottom: (Bool) -> Void = { _ in }

    func makeNSViewController(context: Context) -> LogTextViewController {
        let controller = LogTextViewController()
        controller.onScrolledAwayFromBottom = onScrolledAwayFromBottom
        return controller
    }

    func updateNSViewController(_ controller: LogTextViewController, context: Context) {
        controller.onScrolledAwayFromBottom = onScrolledAwayFromBottom
        controller.apply(document, palette: palette, follow: follow)
    }
}
