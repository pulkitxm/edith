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
}

struct CompanionBackendGateView: View {
    let gate: CompanionBackendGate
    let setUp: () -> Void
    let openBackend: () -> Void
    let retry: () -> Void

    var body: some View {
        switch gate {
        case .proceed:
            EmptyView()
        case .notSetUp:
            PageEmptyState(
                symbolName: "brain.head.profile", title: "Memory is not set up yet",
                message:
                    "Memory remembers your notes, voice memos and files, and answers questions from them. It needs a small background service on a machine you choose.",
                steps: [
                    PageGuideStep(
                        symbolName: "server.rack", title: "Pick a machine",
                        detail: "This Mac or any machine you have added."),
                    PageGuideStep(
                        symbolName: "shippingbox", title: "Install the service",
                        detail: "Edith installs and starts it for you."),
                    PageGuideStep(
                        symbolName: "tray.and.arrow.down", title: "Add your first note",
                        detail: "Drop in a file or record a voice memo."),
                ],
                primary: PageAction("Set up Memory", symbolName: "wand.and.stars", perform: setUp),
                secondary: PageAction("Use an existing backend", perform: openBackend),
                footnote: "Your memory stays on the machine you choose. You can remove it at any time.")
        case .notRunning:
            PageEmptyState(
                symbolName: "bolt.horizontal.circle", title: "Memory is not running",
                message:
                    "Edith cannot reach the memory service. Your saved notes are safe. Open Backend to start it again or see what went wrong.",
                primary: PageAction("Open Backend", symbolName: "server.rack", perform: openBackend),
                secondary: PageAction("Try again", symbolName: "arrow.clockwise", perform: retry))
        }
    }
}
