import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

enum TerminalSessionAction: Equatable {
    case start
    case restart

    var title: String {
        switch self {
        case .start: "Start"
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
                title: "Terminal session ended", detail: exitMessage, showsProgress: false,
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
                        Text(actionError).font(.edithText(.caption)).foregroundStyle(
                            DashSkin.danger
                        ).padding(UIScale.pt(8))
                    }
                    if let exitMessage = holder.exitMessage {
                        HStack {
                            Text(exitMessage).font(.edithText(.caption))
                            Spacer()
                            Button("Restart", action: restart).buttonStyle(.edith(.toolbar))
                        }
                        .padding(UIScale.pt(8))
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
        VStack(spacing: UIScale.pt(10)) {
            Image(systemName: "terminal")
                .font(.system(size: UIScale.pt(24), weight: .light))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(presentation.title)
                .font(.system(size: UIScale.pt(14), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            if let detail = presentation.detail {
                Text(detail)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .multilineTextAlignment(.center)
            }
            if let action = presentation.action {
                Button(action.title) { perform(action) }
                    .buttonStyle(.edith(.primary))
            }
        }
        .padding(UIScale.pt(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func perform(_ action: TerminalSessionAction) {
        restart()
    }
}
