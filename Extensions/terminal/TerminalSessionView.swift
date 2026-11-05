import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

enum TerminalSessionAction: Equatable {
    case start
    case restart

    var title: String {
        switch self {
        case .start: "Start a New Shell"
        case .restart: "Restart"
        }
    }
}

struct TerminalSessionPresentation: Equatable {
    let title: String
    let detail: String?
    let showsProgress: Bool
    let showsTerminal: Bool
    let action: TerminalSessionAction?

    static func make(started: Bool, exitMessage: String?) -> TerminalSessionPresentation {
        if started {
            return TerminalSessionPresentation(
                title: "Terminal running", detail: nil, showsProgress: false,
                showsTerminal: true, action: .restart)
        }
        if let exitMessage {
            return TerminalSessionPresentation(
                title: "This shell stopped", detail: exitMessage, showsProgress: false,
                showsTerminal: false, action: .start)
        }
        return TerminalSessionPresentation(
            title: "Starting local shell…", detail: nil, showsProgress: true,
            showsTerminal: false, action: nil)
    }
}

enum TerminalLaunchPolicy {
    static func shouldStart(active: Bool, started: Bool, exited: Bool) -> Bool {
        active && !started && !exited
    }
}

struct TerminalSessionView: View {
    let holder: TerminalSessionHolder
    var active = true
    var restart: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var palette: TerminalPalette { .edith(dark: dark) }

    var body: some View {
        let presentation = TerminalSessionPresentation.make(
            started: holder.started, exitMessage: holder.error ?? holder.exitMessage)
        Group {
            if presentation.showsTerminal {
                VStack(spacing: 0) {
                    TerminalPane(holder: holder, palette: palette, active: active)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let actionError = holder.actionError {
                        TerminalStatusBar(
                            icon: .warning, message: actionError,
                            tint: DashSkin.danger)
                    }
                    if let exitMessage = holder.exitMessage {
                        TerminalStatusBar(
                            icon: .stop, message: exitMessage,
                            tint: DashSkin.inkSoft(dark), actionTitle: "Restart", action: restart)
                    }
                }
            } else if presentation.showsProgress {
                TerminalLoadingSkeleton(palette: palette)
            } else {
                unavailable(presentation)
            }
        }
        .background(Color(nsColor: palette.background))
    }

    private func unavailable(_ presentation: TerminalSessionPresentation) -> some View {
        TerminalSessionUnavailableView(presentation: presentation, perform: perform)
    }

    private func perform(_ action: TerminalSessionAction) {
        restart()
    }
}

struct TerminalSessionUnavailableView: View {
    let presentation: TerminalSessionPresentation
    let perform: (TerminalSessionAction) -> Void

    var body: some View {
        PageEmptyState(
            icon: .terminal,
            title: presentation.title,
            message: [presentation.detail, "Starting again opens a fresh shell in the same tab."]
                .compactMap { $0 }.joined(separator: " "),
            primary: presentation.action.map { action in
                PageAction(
                    action.title, icon: .refresh,
                    identifier: "terminal.session.start"
                ) { perform(action) }
            }
        )
    }
}

struct TerminalStatusBar: View {
    let icon: EdithIcon
    let message: String
    let tint: Color
    var actionTitle: String?
    var action: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            EdithIconView(icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.ink(scheme == .dark))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: UIScale.pt(8))
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(.edith(.secondary))
            }
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle().fill(DashSkin.line(scheme == .dark)).frame(height: 1)
        }
    }
}
