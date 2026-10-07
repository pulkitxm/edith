import AppKit
import EdithKit
import Observation
import SwiftUI

@MainActor @Observable
final class LaTeXEditorControls {
    var fontSize = 15.0
    var wrapsLines = true
    var line = 1
    var column = 1
    var canUndo = false
    var canRedo = false
    @ObservationIgnored weak var textView: NSTextView?

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }
    func find() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
    }
}

struct LaTeXSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let controls: LaTeXEditorControls
    let dark: Bool
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = LaTeXTextView(frame: .zero, textContainer: container)
        view.isVerticallyResizable = true
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: UIScale.pt(12), height: UIScale.pt(12))
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("LaTeX source")
        view.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LaTeXLineRuler(scrollView: scroll, orientation: .verticalRuler)
        scroll.verticalRulerView?.clientView = view
        scroll.verticalRulerView?.ruleThickness = UIScale.pt(48)
        controls.textView = view
        context.coordinator.view = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let changed =
            view.string != text || context.coordinator.parent.dark != dark
            || context.coordinator.fontSize != UIScale.pt(controls.fontSize)
        context.coordinator.parent = self
        context.coordinator.fontSize = UIScale.pt(controls.fontSize)
        scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        scroll.verticalRulerView?.ruleThickness = UIScale.pt(48)
        view.textContainerInset = NSSize(width: UIScale.pt(12), height: UIScale.pt(12))
        view.isEditable = editable
        let font = NSFont.monospacedSystemFont(
            ofSize: UIScale.pt(controls.fontSize), weight: .regular)
        if changed {
            view.font = font
            view.textColor = dark ? .white : .black
        }
        if changed {
            view.typingAttributes = [
                .font: font, .foregroundColor: dark ? NSColor.white : NSColor.black,
            ]
        }
        view.isHorizontallyResizable = !controls.wrapsLines
        view.autoresizingMask = controls.wrapsLines ? [.width] : []
        view.textContainer?.widthTracksTextView = controls.wrapsLines
        if !controls.wrapsLines {
            view.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        scroll.hasHorizontalScroller = !controls.wrapsLines
        if view.string != text {
            view.string = text
            view.undoManager?.removeAllActions()
        }
        if changed || context.coordinator.highlight == nil {
            context.coordinator.refresh()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
        -> CGSize?
    {
        CGSize(width: proposal.width ?? 500, height: proposal.height ?? 300)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.highlight?.cancel()
        coordinator.view?.delegate = nil
        coordinator.parent.controls.textView = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LaTeXSourceEditor
        weak var view: NSTextView?
        var highlight: Task<Void, Never>?
        var fontSize = 0.0
        init(_ parent: LaTeXSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) { updatePosition() }

        func updatePosition() {
            guard let view else { return }
            let location = min(view.selectedRange().location, (view.string as NSString).length)
            let prefix = (view.string as NSString).substring(to: location)
            parent.controls.line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            parent.controls.column =
                (prefix.split(separator: "\n", omittingEmptySubsequences: false).last?.utf16.count
                    ?? 0) + 1
            parent.controls.canUndo = view.undoManager?.canUndo ?? false
            parent.controls.canRedo = view.undoManager?.canRedo ?? false
        }

        func refresh() {
            highlight?.cancel()
            updatePosition()
            view?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            let source = parent.text
            let dark = parent.dark
            highlight = Task {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                let result = await SyntaxHighlighting.shared.highlight(
                    text: source, language: "latex", dark: dark)
                guard !Task.isCancelled, let view, view.string == source,
                    let storage = view.textStorage
                else { return }
                guard let layout = view.layoutManager, result?.string == source else { return }
                let range = NSRange(location: 0, length: storage.length)
                layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                result?.enumerateAttribute(.foregroundColor, in: range) { color, range, _ in
                    if let color {
                        layout.addTemporaryAttribute(
                            .foregroundColor, value: color, forCharacterRange: range)
                    }
                }
                updatePosition()
                view.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            }
        }
    }
}

final class LaTeXTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = source.substring(
            with: NSRange(location: line.location, length: selection.location - line.location))
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        insertText("\n" + indentation, replacementRange: selection)
    }
}

final class LaTeXLineRuler: NSRulerView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView, let layout = view.layoutManager,
            let container = view.textContainer
        else { return }
        let source = view.string as NSString
        let visible = layout.glyphRange(forBoundingRect: view.visibleRect, in: container)
        let characters = layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        var offset = 0
        var number = 1
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: (view.font?.pointSize ?? 13) * 0.85, weight: .regular)
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            if NSMaxRange(range) >= characters.location && offset <= NSMaxRange(characters) {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let y =
                    fragment.minY + view.textContainerOrigin.y
                    - (scrollView?.contentView.bounds.minY ?? 0)
                let label = String(number) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                ]
                label.draw(
                    at: NSPoint(
                        x: ruleThickness - label.size(withAttributes: attributes).width
                            - UIScale.pt(9), y: y), withAttributes: attributes)
            }
            if offset > NSMaxRange(characters) { break }
            offset = NSMaxRange(range)
            number += 1
        }
    }
}
