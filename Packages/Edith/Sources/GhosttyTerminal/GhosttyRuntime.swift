import AppKit
import GhosttyKit
import OSLog

public struct GhosttyLaunch: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public let workingDirectory: String?

    public init(
        executable: String, arguments: [String], environment: [String],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    var command: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    private let log = Logger(subsystem: "com.pulkit.edith", category: "ghostty")
    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var started = false
    private var tickScheduled = false

    public var isReady: Bool { app != nil }

    public var version: String {
        let info = ghostty_info()
        return String(
            decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)),
            as: UTF8.self)
    }

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        TerminalFontRegistry.register()

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            log.error("ghostty_init failed")
            return
        }

        guard let cfg = ghostty_config_new() else {
            log.error("ghostty_config_new failed")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        config = cfg

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            GhosttyRuntime.from(userdata)?.wakeup()
        }
        runtime.action_cb = { _, target, action in
            GhosttyRuntime.shared.perform(action: action, target: target)
        }
        runtime.read_clipboard_cb = { userdata, location, state, _, _, _ in
            GhosttyRuntime.readClipboard(userdata, location, state)
        }
        runtime.confirm_read_clipboard_cb = { userdata, confirmation, state, request in
            GhosttyRuntime.confirmClipboard(userdata, confirmation, state, request)
        }
        runtime.write_clipboard_cb = { _, location, content, count, _ in
            GhosttyRuntime.writeClipboard(location, content, count)
        }
        runtime.close_surface_cb = { userdata, _ in
            GhosttySurfaceRegistry.shared.close(userdata)
        }

        guard let created = ghostty_app_new(&runtime, cfg) else {
            log.error("ghostty_app_new failed")
            return
        }
        app = created
    }

    var handle: ghostty_app_t? { app }

    var configHandle: ghostty_config_t? { config }

    func configuration(for theme: GhosttyTheme) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(cfg)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-ghostty", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(abs(theme.configuration.hashValue)).conf")
        do {
            try theme.configuration.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            log.error("could not write the terminal theme: \(error.localizedDescription)")
            ghostty_config_finalize(cfg)
            return cfg
        }
        file.path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        return cfg
    }

    private static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private func wakeup() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.tickScheduled else { return }
            self.tickScheduled = true
            DispatchQueue.main.async {
                self.tickScheduled = false
                guard let app = self.app else { return }
                ghostty_app_tick(app)
            }
        }
    }

    private func perform(action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            GhosttySurfaceRegistry.shared.render(target)
            return true
        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            GhosttySurfaceRegistry.shared.requestClose(target)
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            guard let view = GhosttySurfaceRegistry.shared.view(target),
                let value = GhosttyTerminalView.decoded(
                    action.action.open_url.url, count: Int(action.action.open_url.len))
            else { return false }
            return onMain { view.openTerminalTarget(value) }
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            onMain { view.setMouseShape(action.action.mouse_shape) }
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            onMain {
                view.setMouseVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
            }
            return true
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            let value = GhosttyTerminalView.decoded(
                action.action.mouse_over_link.url, count: action.action.mouse_over_link.len)
            onMain { view.setHoveredLink(value) }
            return true
        case GHOSTTY_ACTION_SELECTION_CHANGED:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            onMain { view.selectionChanged() }
            return true
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE,
            GHOSTTY_ACTION_SET_WINDOW_TITLE:
            guard let view = GhosttySurfaceRegistry.shared.view(target),
                let value = GhosttyTerminalView.decoded(action.action.set_title.title)
            else { return false }
            onMain { view.setTerminalTitle(value) }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let view = GhosttySurfaceRegistry.shared.view(target),
                let value = GhosttyTerminalView.decoded(action.action.pwd.pwd)
            else { return false }
            onMain { view.setWorkingDirectory(value) }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            onMain { NSSound.beep() }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            let needle = GhosttyTerminalView.decoded(action.action.start_search.needle) ?? ""
            onMain { view.beginSearch(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            onMain { view.endSearch() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            let value = action.action.search_total.total
            onMain { view.setSearchTotal(value >= 0 ? value : nil) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            let value = action.action.search_selected.selected
            onMain { view.setSearchSelected(value >= 0 ? value : nil) }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let view = GhosttySurfaceRegistry.shared.view(target) else { return false }
            let report = action.action.progress_report
            onMain { view.setProgress(report.state, progress: Int(report.progress)) }
            return true
        default:
            return false
        }
    }

    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.sync(execute: action)
        }
    }

    private func onMain(_ action: () -> Bool) -> Bool {
        if Thread.isMainThread { return action() }
        return DispatchQueue.main.sync(execute: action)
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> ghostty_clipboard_read_result_e {
        guard let surface = GhosttySurfaceRegistry.shared.surface(userdata),
            let text = NSPasteboard.general.string(forType: .string)
        else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        let bytes = Array(text.utf8CString)
        let mime = Array("text/plain;charset=utf-8".utf8CString)
        bytes.withUnsafeBufferPointer { data in
            mime.withUnsafeBufferPointer { mimePointer in
                var content = ghostty_clipboard_content_s(
                    mime: mimePointer.baseAddress,
                    data: data.baseAddress,
                    len: max(0, data.count - 1))
                withUnsafePointer(to: &content) { contentPointer in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentPointer,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: true,
                        remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private static func confirmClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ confirmation: UnsafePointer<ghostty_clipboard_confirm_s>?,
        _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
    ) {
        guard let surface = GhosttySurfaceRegistry.shared.surface(userdata), let confirmation,
            let state
        else { return }
        let approved = GhosttyRuntime.shared.onMain {
            let alert = NSAlert()
            alert.messageText = confirmationTitle(for: request)
            alert.informativeText = confirmationDetail(confirmation.pointee)
            alert.alertStyle = .warning
            alert.addButton(withTitle: confirmationButton(for: request))
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard approved else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        var complete = ghostty_clipboard_complete_s(
            contents: confirmation.pointee.contents,
            contents_len: confirmation.pointee.contents_len,
            available: confirmation.pointee.available,
            available_len: confirmation.pointee.available_len,
            confirmed: true,
            remember: false)
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }

    private static func confirmationTitle(for request: ghostty_clipboard_request_e) -> String {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
            GHOSTTY_CLIPBOARD_REQUEST_LIST:
            return "Allow terminal clipboard access?"
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            return "Allow terminal to change the clipboard?"
        default:
            return "Paste into the terminal?"
        }
    }

    private static func confirmationButton(for request: ghostty_clipboard_request_e) -> String {
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
            GHOSTTY_CLIPBOARD_REQUEST_LIST:
            return "Allow"
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE:
            return "Change Clipboard"
        default:
            return "Paste"
        }
    }

    private static func confirmationDetail(_ confirmation: ghostty_clipboard_confirm_s) -> String {
        guard let contents = confirmation.contents, confirmation.contents_len > 0 else {
            return "A program in this terminal requested clipboard access."
        }
        let entry = contents[0]
        guard let raw = entry.data, entry.len > 0 else {
            return "A program in this terminal requested clipboard access."
        }
        let text = String(
            decoding: UnsafeRawBufferPointer(start: raw, count: min(Int(entry.len), 240)),
            as: UTF8.self)
        return text.count < Int(entry.len) ? "\(text)…" : text
    }

    private static func writeClipboard(
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return }
        TerminalClipboard.write(
            TerminalClipboard.entries(from: content, count: count), to: .general)
    }
}
