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
        guard value.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    private let log = Logger(subsystem: "com.pulkit.edith", category: "ghostty")
    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var started = false

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
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            GhosttyRuntime.writeClipboard(content, count)
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

    private static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyRuntime? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private func wakeup() {
        DispatchQueue.main.async { [weak self] in
            guard let app = self?.app else { return }
            ghostty_app_tick(app)
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
        default:
            return false
        }
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
        var bytes = Array(text.utf8CString)
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

    private static func writeClipboard(
        _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int
    ) {
        guard let content, count > 0 else { return }
        var text = ""
        for index in 0..<count {
            let entry = content[index]
            guard let raw = entry.data, entry.len > 0 else { continue }
            let buffer = UnsafeRawBufferPointer(start: raw, count: entry.len)
            text += String(decoding: buffer, as: UTF8.self)
        }
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
