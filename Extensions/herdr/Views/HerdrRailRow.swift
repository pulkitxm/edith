import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrRailRow: View, Equatable {
    let store: HerdrStore
    let agent: HerdrAgent
    let hideAgents: Bool
    let launchEnabled: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    static func == (lhs: HerdrRailRow, rhs: HerdrRailRow) -> Bool {
        lhs.store === rhs.store && lhs.agent == rhs.agent && lhs.hideAgents == rhs.hideAgents
            && lhs.launchEnabled == rhs.launchEnabled
    }

    var body: some View {
        let highlight = store.railMark(for: agent.id)
        let selected = highlight == .solo || highlight == .focused
        return Button {
            Self.open(agent, store: store, launchEnabled: launchEnabled)
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(8)) {
                HerdrKindMark(kind: agent.kind, size: UIScale.pt(13))
                    .foregroundStyle(
                        agent.isTerminal ? DashSkin.accent(dark) : DashSkin.inkSoft(dark)
                    )
                    .padding(.top, UIScale.pt(2))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(agent.title)
                        .font(
                            .system(
                                size: UIScale.pt(12.5), weight: selected ? .semibold : .medium)
                        )
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .presenterTextBlur(hideAgents, fontSize: 12.5)
                    Text(rowDetail(agent))
                        .font(DashSkin.mono(9.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                        .presenterTextBlur(hideAgents, fontSize: 9.5)
                }
                Spacer(minLength: 0)
                let waiting = store.messaging.armedHooks(for: agent.id)
                if !waiting.isEmpty {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.accent(dark))
                        .padding(.top, UIScale.pt(2))
                        .help(waitingHelp(waiting))
                        .accessibilityLabel(waitingHelp(waiting))
                }
            }
            .padding(.leading, UIScale.pt(12))
            .padding(.trailing, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(8))
            .widgetBar(
                cornerRadius: 8,
                fill: HerdrStatusColor.fill(agent, dark: dark, selected: selected),
                stroke: selected
                    ? HerdrStatusColor.stroke(agent, dark: dark, selected: true) : .clear,
                strokeWidth: selected ? 1.4 : 0
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(DashSkin.accent(dark))
                        .frame(width: UIScale.pt(3))
                        .padding(.vertical, UIScale.pt(6))
                        .padding(.leading, UIScale.pt(5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityValueIfPresent(rowValue(highlight))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(rowHelp(agent, highlight: highlight, selected: selected))
        .herdrDraggable(.agent(agent), simultaneous: true)
        .herdrAgentContextMenu(agent, store: store)
        .herdrDropFrame(HerdrDropGeometry.agentPrefix + agent.id)
    }

    private func waitingHelp(_ hooks: [HerdrAgentHook]) -> String {
        if hooks.count == 1 { return hooks[0].schedule.sendsPhrase(now: Date()) }
        return "\(hooks.count) messages waiting"
    }

    private func rowValue(_ highlight: HerdrRailHighlight) -> String {
        if highlight == .focused { return "Focused" }
        if highlight == .grouped { return "In this side by side tab" }
        if highlight == .solo { return "Open on the right" }
        return ""
    }

    private func rowHelp(
        _ agent: HerdrAgent, highlight: HerdrRailHighlight, selected: Bool
    ) -> String {
        if highlight == .focused {
            return "\(agent.title): focused in this side by side tab"
        }
        if highlight == .grouped {
            return "\(agent.title): in this side by side tab"
        }
        if selected {
            return "\(agent.title): open on the right"
        }
        return
            "\(agent.title). Drag in the sidebar to reorder, or onto the right side to place it beside other agents."
    }

    private func rowDetail(_ agent: HerdrAgent) -> String {
        agent.isTerminal
            ? agent.machineName : "\(agent.kind) · \(agent.machineName) · \(agent.pane)"
    }

    static func open(_ agent: HerdrAgent, store: HerdrStore, launchEnabled: Bool) {
        if store.raiseSpace(containingAgent: agent.id) { return }
        let detaching = NSEvent.modifierFlags.contains(.command)
        if detaching {
            if store.uiClient == nil { store.close(agent.id, rememberingPlacement: false) }
            HerdrAgentWindow.open(agent: agent, store: store, launchEnabled: launchEnabled)
            return
        }
        if store.raiseAgentWindow(agent.id) { return }
        store.open(agent)
    }
}
