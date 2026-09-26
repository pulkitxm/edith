import EdithKit
import SwiftUI

struct HerdrMessageSheet: View {
    let messaging: HerdrMessaging
    let initial: HerdrMessageDraft
    var hideAgents = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @State private var delivery: HerdrMessageDraft.Delivery
    @State private var sending = false
    @State private var outcomes: [String: HerdrPromptOutcome]?
    @FocusState private var editorFocused: Bool

    init(messaging: HerdrMessaging, draft: HerdrMessageDraft, hideAgents: Bool = false) {
        self.messaging = messaging
        initial = draft
        self.hideAgents = hideAgents
        _delivery = State(initialValue: draft.delivery)
    }

    private var dark: Bool { scheme == .dark }
    private var canSend: Bool { HerdrAgentPrompt.normalized(text) != nil && !sending }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            header
            if let outcomes {
                results(outcomes)
            } else {
                composer
            }
            footer
        }
        .padding(UIScale.pt(16))
        .frame(width: UIScale.pt(460))
        .background(DashSkin.paper(dark))
        .onAppear { editorFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(initial.title)
                .font(DashSkin.heading(17))
                .foregroundStyle(DashSkin.ink(dark))
                .presenterTextBlur(hideAgents && initial.single != nil, fontSize: 17)
            Text(subtitle)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        if let group = initial.group {
            let count = initial.recipients.count
            return "\(count) \(count == 1 ? "agent" : "agents"). \(group.detail)"
        }
        switch delivery {
        case .now:
            return "Herdr types it into the agent and presses Return."
        case .whenFinished:
            return
                "Edith watches the agent and sends this once, the next time it finishes a turn."
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            if initial.single != nil {
                Picker("Delivery", selection: $delivery) {
                    ForEach(HerdrMessageDraft.Delivery.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                recipientList
            }
            TextEditor(text: $text)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(UIScale.pt(8))
                .frame(height: UIScale.pt(120))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .strokeBorder(DashSkin.line(dark))
                }
                .accessibilityLabel("Message")
            if let error = messaging.errorMessage {
                Text(error)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.red)
            }
        }
    }

    private var recipientList: some View {
        let names = initial.recipients.prefix(6).map(\.title)
        let rest = initial.recipients.count - names.count
        return Text(names.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : ""))
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .lineLimit(2)
            .presenterTextBlur(hideAgents, fontSize: 11)
    }

    private func results(_ outcomes: [String: HerdrPromptOutcome]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(initial.recipients) { agent in
                    let outcome = outcomes[agent.id] ?? .failed("no reply")
                    HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                        Image(
                            systemName: outcome.delivered
                                ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .foregroundStyle(outcome.delivered ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                            Text(agent.title)
                                .font(.system(size: UIScale.pt(12), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                                .presenterTextBlur(hideAgents, fontSize: 12)
                            Text("\(agent.machineName) · \(outcome.summary)")
                                .font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: UIScale.pt(220))
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(8)) {
            if let outcomes {
                let delivered = outcomes.values.filter(\.delivered).count
                Text("Submitted to \(delivered) of \(initial.recipients.count)")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.edith(.primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.edith(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(sendTitle) { Task { await submit() } }
                    .buttonStyle(.edith(.primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help("Send (⌘↩)")
            }
        }
    }

    private var sendTitle: String {
        if sending { return "Sending…" }
        return delivery == .whenFinished && initial.single != nil ? "Arm" : "Send"
    }

    private func submit() async {
        guard canSend else { return }
        sending = true
        defer { sending = false }
        if delivery == .whenFinished, let agent = initial.single {
            if await messaging.arm(text, for: agent) { dismiss() }
            return
        }
        let replies = await messaging.send(text, to: initial.recipients)
        if initial.single != nil, replies.values.allSatisfy(\.delivered) {
            dismiss()
            return
        }
        outcomes = replies
    }
}
