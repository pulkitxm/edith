import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor enum HerdrTerminalMachines {
    static var shared: Self { .inventory }
    case inventory
    func knows(_ id: UUID) -> Bool {
        id == Machine.localID || MachineRegistry.machines().contains { $0.id == id }
    }
}

struct HerdrShellTerminal: View {
    let store: HerdrStore
    let paneID: UUID
    let target: PaneTarget
    let holder: TerminalSessionHolder
    let active: Bool
    let wantsFocus: Bool
    let launchEnabled: Bool
    var onFocus: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var error: String?
    var body: some View {
        ZStack {
            TerminalPane(
                holder: holder, palette: .edith(dark: scheme == .dark), active: active,
                wantsFocus: wantsFocus, fontSize: store.terminalSettings.fontSize, onFocus: onFocus)
            if let error {
                VStack(spacing: UIScale.pt(10)) {
                    Text(error).font(.edithText(.body)).textSelection(.enabled)
                    Button("Retry") {
                        self.error = nil; holder.reset()
                    }.buttonStyle(.edith(.secondary))
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(
                    DashSkin.paper(scheme == .dark))
            }
        }
        .task(id: active && launchEnabled && error == nil) {
            guard active, launchEnabled, error == nil, !holder.started else { return }
            do {
                try await store.connectShell(holder, paneID: paneID, target: target)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
