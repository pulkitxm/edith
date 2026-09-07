import AppKit
import Foundation
import UniformTypeIdentifiers

enum TerminalURLDenial: Equatable {
    case malformed
    case unsafeCharacters
    case invalidWebURL
    case inaccessibleFile
    case unsafeFile
    case remoteSessionFile

    var message: String {
        switch self {
        case .malformed:
            return "The target is not a valid absolute URL."
        case .unsafeCharacters:
            return "The target contains invisible or line-breaking characters."
        case .invalidWebURL:
            return "The web target does not contain a valid host."
        case .inaccessibleFile:
            return "The local target does not exist or cannot be opened safely."
        case .unsafeFile:
            return "Opening this local target could execute code."
        case .remoteSessionFile:
            return "A remote terminal cannot open a path on this Mac."
        }
    }
}

enum TerminalURLDecision: Equatable {
    case allow(URL)
    case confirm(URL)
    case deny(TerminalURLDenial)
}

struct TerminalUntrustedURL: Equatable {
    let value: String
    let allowsLocalFiles: Bool

    init(value: String, allowsLocalFiles: Bool = true) {
        self.value = value
        self.allowsLocalFiles = allowsLocalFiles
    }

    var decision: TerminalURLDecision {
        guard !value.isEmpty else { return .deny(.malformed) }
        guard !value.unicodeScalars.contains(where: Self.isUnsafeCharacter) else {
            return .deny(.unsafeCharacters)
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), !scheme.isEmpty
        else { return .deny(.malformed) }

        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return .deny(.invalidWebURL) }
            return .allow(url)
        case "mailto":
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                !components.path.isEmpty
            else { return .deny(.malformed) }
            return .allow(url)
        case "file":
            guard allowsLocalFiles else { return .deny(.remoteSessionFile) }
            return fileDecision(url)
        default:
            return .confirm(url)
        }
    }

    var displayValue: String {
        let normalized: String
        if let url = URL(string: value), url.isFileURL {
            normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
        } else {
            normalized = value
        }
        return normalized.unicodeScalars.reduce(into: "") { result, scalar in
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    private func fileDecision(_ url: URL) -> TerminalURLDecision {
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformed)
        }
        if let host = url.host, !host.isEmpty,
            host.caseInsensitiveCompare("localhost") != .orderedSame
        {
            return .deny(.malformed)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(forKeys: [
                .contentTypeKey, .isDirectoryKey, .isExecutableKey, .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }
        guard values.isDirectory == true || values.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(resolved, values: values) else {
            return .deny(.unsafeFile)
        }
        return .allow(resolved)
    }

    private static func isUnsafeFile(_ url: URL, values: URLResourceValues) -> Bool {
        if unsafeExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let contentType = values.contentType,
            unsafeTypes.contains(where: { contentType.conforms(to: $0) })
        {
            return true
        }
        return values.isDirectory != true && values.isExecutable == true
    }

    private static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x2028...0x202E,
            0x2060, 0x2066...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static let unsafeExtensions: Set<String> = [
        "action", "app", "applescript", "class", "command", "desktop", "inetloc", "jar",
        "mobileconfig", "mpkg", "pkg", "scpt", "terminal", "tool", "url", "webloc",
        "workflow",
    ]

    private static let unsafeTypes: [UTType] = [.application, .executable, .script]
}

@MainActor
enum TerminalUntrustedURLPresenter {
    static func open(_ target: TerminalUntrustedURL, from window: NSWindow?) {
        switch target.decision {
        case .allow(let url):
            NSWorkspace.shared.open(url)
        case .confirm(let url):
            confirm(url, target: target.displayValue, from: window)
        case .deny(let reason):
            block(reason, target: target.displayValue, from: window)
        }
    }

    private static func confirm(_ url: URL, target: String, from window: NSWindow?) {
        let workspace = NSWorkspace.shared
        let handler =
            workspace.urlForApplication(toOpen: url)
            .map { $0.deletingPathExtension().lastPathComponent }
            ?? "the default application"
        let alert = alert(
            title: "Open Link from Terminal Output?",
            detail:
                "This link will open in \(handler). Continue only if you trust the destination.",
            target: target, buttons: ["Cancel", "Open Link"])
        present(alert, from: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            workspace.open(url)
        }
    }

    private static func block(
        _ reason: TerminalURLDenial, target: String, from window: NSWindow?
    ) {
        let alert = alert(
            title: "Edith Blocked This Terminal Link", detail: reason.message,
            target: target, buttons: ["OK", "Copy Target"])
        present(alert, from: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(target, forType: .string)
        }
    }

    private static func alert(
        title: String, detail: String, target: String, buttons: [String]
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.messageText = title
        alert.informativeText = detail
        alert.accessoryView = targetView(target)
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    private static func present(
        _ alert: NSAlert, from window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private static func targetView(_ target: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 88))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.string = target
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }
}
