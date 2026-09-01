import AppKit
import GhosttyKit

final class TerminalLinkHoverView: NSView {
    private let backdrop = NSVisualEffectView(frame: .zero)
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "⌘ click to open")

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
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 10.5, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(backdrop)
        backdrop.addSubview(icon)
        backdrop.addSubview(label)
        backdrop.addSubview(hint)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdrop.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            icon.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -5),
            hint.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            hint.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ value: String?) {
        let value = value?.isEmpty == false ? value : nil
        label.stringValue = value ?? ""
        setAccessibilityLabel(value.map { "Link \($0). Command-click to open." })
        isHidden = value == nil
    }
}

final class TerminalSearchField: NSSearchField {
    var onClose: (() -> Void)?
    var onNext: ((Bool) -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            onNext?(flags.contains(.shift))
            return
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "g" {
            onNext?(false)
            return
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            onNext?(true)
            return
        }
        super.keyDown(with: event)
    }
}

final class TerminalSearchBar: NSVisualEffectView, NSSearchFieldDelegate {
    let field = TerminalSearchField(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    var onQuery: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private var queryTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        field.placeholderString = "Find in terminal"
        field.delegate = self
        field.onClose = { [weak self] in self?.onClose?() }
        field.onNext = { [weak self] previous in self?.onNavigate?(previous) }
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        configure(previousButton, symbol: "chevron.up", action: #selector(previous))
        configure(nextButton, symbol: "chevron.down", action: #selector(next))
        configure(closeButton, symbol: "xmark", action: #selector(close))
        let stack = NSStackView(views: [field, countLabel, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 210),
            countLabel.widthAnchor.constraint(equalToConstant: 64),
            previousButton.widthAnchor.constraint(equalToConstant: 24),
            nextButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        queryTask?.cancel()
    }

    func controlTextDidChange(_ notification: Notification) {
        let query = field.stringValue
        queryTask?.cancel()
        guard Self.shouldDebounce(query) else {
            onQuery?(query)
            return
        }
        queryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            onQuery?(query)
            queryTask = nil
        }
    }

    static func shouldDebounce(_ query: String) -> Bool { (1...2).contains(query.count) }

    func begin(_ needle: String, in window: NSWindow?) {
        queryTask?.cancel()
        queryTask = nil
        field.stringValue = needle
        isHidden = false
        onQuery?(needle)
        window?.makeFirstResponder(field)
    }

    func update(selected: Int?, total: Int?) {
        guard let total, total > 0 else {
            countLabel.stringValue = "No results"
            return
        }
        let selected = min(total, max(1, (selected ?? 0) + 1))
        countLabel.stringValue = "\(selected) of \(total)"
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
    }

    @objc private func previous() {
        onNavigate?(true)
    }

    @objc private func next() {
        onNavigate?(false)
    }

    @objc private func close() {
        onClose?()
    }
}

final class TerminalProgressStrip: NSProgressIndicator {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .bar
        minValue = 0
        maxValue = 100
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func update(_ state: ghostty_action_progress_report_state_e, progress: Int) {
        switch state {
        case GHOSTTY_PROGRESS_STATE_REMOVE:
            stopAnimation(nil)
            isHidden = true
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
            isHidden = false
            isIndeterminate = true
            startAnimation(nil)
        default:
            stopAnimation(nil)
            isHidden = false
            isIndeterminate = progress < 0
            doubleValue = Double(max(0, progress))
            if isIndeterminate { startAnimation(nil) }
        }
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
        allowsLocalFiles: Bool = true,
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
            if scheme == "file" {
                guard allowsLocalFiles else { return nil }
                return url.standardizedFileURL
            }
            return url
        }

        guard allowsLocalFiles else { return nil }

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

    func openTerminalTarget(
        _ rawValue: String,
        kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    ) -> Bool {
        if kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 {
            commandClickOpenedTarget = true
            let target = TerminalUntrustedURL(
                value: rawValue, allowsLocalFiles: allowsLocalFileLinks)
            let presentingWindow = window
            DispatchQueue.main.async {
                TerminalUntrustedURLPresenter.open(target, from: presentingWindow)
            }
            return true
        }
        guard
            let url = Self.linkTarget(
                for: rawValue, workingDirectory: currentDirectory,
                allowsLocalFiles: allowsLocalFileLinks)
        else {
            return false
        }
        commandClickOpenedTarget = true
        let openResolvedURL = openResolvedURL
        DispatchQueue.main.async {
            openResolvedURL(url)
        }
        return true
    }

    func setHoveredLink(_ value: String?) {
        let value = value.flatMap { $0.isEmpty ? nil : $0 }
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
        accessibilitySelectionTask?.cancel()
        accessibilitySelectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
            accessibilitySelectionTask = nil
        }
    }

    func beginSearch(_ needle: String) {
        searchSelected = nil
        searchTotal = nil
        searchBar.update(selected: nil, total: nil)
        searchBar.begin(needle, in: window)
    }

    func endSearch() {
        searchBar.isHidden = true
        window?.makeFirstResponder(self)
    }

    func setSearchTotal(_ value: Int?) {
        searchTotal = value
        searchBar.update(selected: searchSelected, total: searchTotal)
    }

    func setSearchSelected(_ value: Int?) {
        searchSelected = value
        searchBar.update(selected: searchSelected, total: searchTotal)
    }

    func setProgress(_ state: ghostty_action_progress_report_state_e, progress: Int) {
        progressStrip.update(state, progress: progress)
    }

}
