import AppKit

public struct TerminalLinkResolution: Codable, Sendable {
    public enum Disposition: String, Codable, Sendable { case allow, confirm, deny }
    public let disposition: Disposition
    public let target: String
    public let detail: String

    public static func resolve(
        _ value: String, directory: String, untrusted: Bool, allowsLocalFiles: Bool = true,
        handler: (URL) -> String = {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.deletingPathExtension()
                .lastPathComponent ?? "the default application"
        }
    ) -> Self {
        if !untrusted {
            guard
                let url = GhosttyTerminalView.linkTarget(
                    for: value, workingDirectory: directory, allowsLocalFiles: allowsLocalFiles)
            else {
                return Self(
                    disposition: .deny, target: value, detail: "The terminal target is unavailable."
                )
            }
            return Self(disposition: .allow, target: url.absoluteString, detail: "")
        }
        let target = TerminalUntrustedURL(value: value, allowsLocalFiles: allowsLocalFiles)
        switch target.decision {
        case let .allow(url):
            return Self(disposition: .allow, target: url.absoluteString, detail: "")
        case let .confirm(url):
            return Self(
                disposition: .confirm, target: url.absoluteString,
                detail:
                    "This link will open in \(handler(url)). Continue only if you trust the destination."
            )
        case let .deny(reason):
            return Self(disposition: .deny, target: target.displayValue, detail: reason.message)
        }
    }
}

extension GhosttyTerminalView {
    public func presentLink(_ resolution: TerminalLinkResolution, open: @escaping () -> Void) {
        guard surface != nil else { return }
        TerminalUntrustedURLPresenter.present(resolution, from: window, open: open)
    }
}
