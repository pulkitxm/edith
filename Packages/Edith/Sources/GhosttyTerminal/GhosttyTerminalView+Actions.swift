import AppKit
import GhosttyKit

final class TerminalLinkHoverView: NSView {
    private let backdrop = NSVisualEffectView(frame: .zero)
    private let label = NSTextField(labelWithString: "")

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 6
        backdrop.layer?.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(backdrop)
        backdrop.addSubview(label)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ value: String?) {
        let value = value?.isEmpty == false ? value : nil
        label.stringValue = value ?? ""
        label.setAccessibilityLabel(value)
        isHidden = value == nil
    }
}

extension GhosttyTerminalView {
    static func decoded(_ bytes: UnsafePointer<CChar>?, count: Int? = nil) -> String? {
        guard let bytes else { return nil }
        if let count {
            return String(
                decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
        return String(cString: bytes)
    }

    static func linkTarget(
        for rawValue: String, workingDirectory: String?,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("<", ">")]
        for wrapper in wrappers where value.first == wrapper.0 && value.last == wrapper.1 {
            value.removeFirst()
            value.removeLast()
        }
        while let last = value.last, ".,;!?".contains(last) { value.removeLast() }
        guard !value.isEmpty else { return nil }

        let lowercase = value.lowercased()
        if lowercase.hasPrefix("localhost:") || lowercase.hasPrefix("127.0.0.1:")
            || lowercase.hasPrefix("[::1]:")
        {
            return URL(string: "http://\(value)")
        }

        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            guard scheme != "javascript", scheme != "data" else { return nil }
            if scheme == "file" { return url.standardizedFileURL }
            return url
        }

        var path = value
        if path.hasPrefix("~") {
            path = NSString(string: path).expandingTildeInPath
        } else if !path.hasPrefix("/") {
            guard let workingDirectory, !workingDirectory.isEmpty else { return nil }
            path =
                URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(path).path
        }

        if !fileExists(path) {
            var components = path.split(separator: ":", omittingEmptySubsequences: false)
            while components.count > 1, Int(components.last ?? "") != nil {
                components.removeLast()
                let candidate = components.joined(separator: ":")
                if fileExists(candidate) {
                    path = candidate
                    break
                }
            }
        }
        guard fileExists(path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    func openTerminalTarget(_ rawValue: String) -> Bool {
        guard let url = Self.linkTarget(for: rawValue, workingDirectory: currentDirectory) else {
            return false
        }
        commandClickOpenedTarget = true
        return NSWorkspace.shared.open(url)
    }

    func setHoveredLink(_ value: String?) {
        hoveredLink = value
        linkHoverView.show(value)
    }

    func setWorkingDirectory(_ value: String) {
        currentDirectory = value
        onWorkingDirectoryChange?(value)
    }

    func setTerminalTitle(_ value: String) {
        setAccessibilityLabel(value)
        onTitleChange?(value)
    }

    func setMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER, GHOSTTY_MOUSE_SHAPE_HELP:
            terminalCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_CELL:
            terminalCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            terminalCursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            terminalCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            terminalCursor = .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_ALIAS:
            terminalCursor = .dragLink
        case GHOSTTY_MOUSE_SHAPE_COPY:
            terminalCursor = .dragCopy
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            terminalCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            terminalCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            terminalCursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE,
            GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            terminalCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE,
            GHOSTTY_MOUSE_SHAPE_S_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            terminalCursor = .resizeUpDown
        default:
            terminalCursor = .arrow
        }
        window?.invalidateCursorRects(for: self)
        terminalCursor.set()
    }

    func setMouseVisible(_ visible: Bool) {
        guard visible == cursorHidden else { return }
        cursorHidden = !visible
        if visible {
            NSCursor.unhide()
        } else {
            NSCursor.hide()
        }
    }

    func selectionChanged() {
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    public override func accessibilityValue() -> Any? { selectedText() ?? "" }

    public override func accessibilitySelectedText() -> String? { selectedText() }
}
