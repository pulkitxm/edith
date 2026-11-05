import EdithExtensionUI
import SwiftUI

enum CompanionBackendGate: Equatable {
    case proceed
    case notSetUp
    case notRunning

    static func resolve(
        tab: CompanionTab, checked: Bool, reachable: Bool, hasDeployment: Bool
    ) -> CompanionBackendGate {
        guard checked, !reachable else { return .proceed }
        guard tab != .setup, tab != .settings else { return .proceed }
        return hasDeployment ? .notRunning : .notSetUp
    }
}

enum CompanionMemoryState: Equatable {
    case empty
    case populated

    static func resolve(status: CompanionStatus?) -> CompanionMemoryState {
        guard let status else { return .populated }
        return status.episodes == 0 && status.chunks == 0 ? .empty : .populated
    }

    static func summary(status: CompanionStatus?) -> String? {
        guard let status, resolve(status: status) == .populated else { return nil }
        var parts = [status.episodes == 1 ? "1 item saved" : "\(status.episodes) items saved"]
        if status.observations > 0 {
            parts.append(
                status.observations == 1 ? "1 observation" : "\(status.observations) observations")
        }
        return parts.joined(separator: ", ")
    }
}

struct CompanionFittingEmptyState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
            ScrollView { content() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CompanionCenteredChips<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) { content() }
            VStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) { content() }
        }
    }
}

struct CompanionBackendGateView: View {
    let gate: CompanionBackendGate
    let setUp: () -> Void
    let openBackend: () -> Void
    let retry: () -> Void

    var body: some View {
        CompanionFittingEmptyState { state }
    }

    @ViewBuilder
    private var state: some View {
        switch gate {
        case .proceed:
            EmptyView()
        case .notSetUp:
            PageEmptyState(
                icon: .companion, title: "Memory is not set up yet",
                message:
                    "Memory keeps your notes, voice memos and files, and answers questions from them. It runs as a small set of containers on a machine you choose and needs about 12 GB of disk.",
                steps: [
                    PageGuideStep(
                        icon: .server, title: "Pick a machine",
                        detail: "This Mac or any machine you have added."),
                    PageGuideStep(
                        icon: .box, title: "Install the service",
                        detail: "Edith sets it up and starts it for you."),
                    PageGuideStep(
                        icon: .tray, title: "Add your first note",
                        detail: "Drop in a file or record a voice memo."),
                ],
                primary: PageAction("Set up Memory", icon: .adjust, perform: setUp),
                secondary: PageAction("Open Backend", perform: openBackend),
                footnote:
                    "Your memory stays on the machine you choose. You can remove it at any time.")
        case .notRunning:
            PageEmptyState(
                icon: .bolt, title: "Memory is not running",
                message:
                    "Edith cannot reach the memory service. Your saved notes are safe. Open Backend to start it again or see what went wrong.",
                primary: PageAction(
                    "Open Backend", icon: .server, perform: openBackend),
                secondary: PageAction("Try again", icon: .refresh, perform: retry))
        }
    }
}
