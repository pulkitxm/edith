import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct AgentApprovalCard: View {
    let request: AgentApprovalRequest
    let monitor: AgentActivityMonitor
    var dense: Bool
    var showsActions: Bool
    @State private var detailHeight: CGFloat = 20
    @State private var input: AgentApprovalInput

    init(
        request: AgentApprovalRequest, monitor: AgentActivityMonitor, dense: Bool = false,
        showsActions: Bool = true
    ) {
        self.request = request
        self.monitor = monitor
        self.dense = dense
        self.showsActions = showsActions
        _input = State(initialValue: AgentApprovalInput(request.detail))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack {
                Label(request.tool, systemImage: "hand.raised.fill").font(.edithText(.callout))
                Spacer(minLength: 0)
                Text("\(max(0, Int(request.expiresAt.timeIntervalSince(monitor.now))))s").font(
                    .edithText(.caption)
                ).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(
                request.provider.title + " · "
                    + URL(fileURLWithPath: request.project).lastPathComponent
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
            .opacity(PresenterState.shared.hidesAgents ? 0 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                    ForEach(input.fields) { field in
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            if input.fields.count > 1 || field.id != "details" {
                                Text(field.title).font(.edithText(.caption2)).foregroundStyle(
                                    .secondary)
                            }
                            Text(field.value).font(.edithText(.caption)).monospaced().textSelection(
                                .enabled
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    detailHeight = $0
                }
            }.frame(height: min(UIScale.pt(dense ? 64 : 120), detailHeight)).opacity(
                PresenterState.shared.hidesAgents ? 0 : 1)
            if let error = monitor.decisionErrors[request.id] {
                Text(error).font(.edithText(.caption)).foregroundStyle(.red)
            }
            if showsActions {
                HStack {
                    Button("Deny") {
                        HerdrWorkOwnership.start { await monitor.decide(request, choice: .deny) }
                    }
                    .buttonStyle(.edith(.secondary))
                    Spacer(minLength: 0)
                    Button("Allow once") {
                        HerdrWorkOwnership.start {
                            await monitor.decide(request, choice: .allowOnce)
                        }
                    }.buttonStyle(.edith(.primary))
                }.disabled(
                    monitor.deciding.contains(request.id) || request.expiresAt <= monitor.now)
            }
        }
        .disabled(PresenterState.shared.hidesAgents)
        .padding(UIScale.pt(10)).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(10)).stroke(Color.orange.opacity(0.3)))
    }
}

enum AgentActivityStyle {
    static func color(_ phase: AgentActivityPhase) -> Color {
        switch phase {
        case .working: .green
        case .permission, .blocked, .waiting: .orange
        case .error, .stuck: .red
        case .finished: .blue
        case .idle, .quiet, .ended: .secondary
        }
    }
}
