import EdithKit
import SwiftUI

struct HerdrMessageSheet: View {
    let messaging: HerdrMessaging
    let initial: HerdrMessageDraft
    var hideAgents = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var text = ""
    @State private var mode: HerdrMessageDraft.Delivery
    @State private var hours = 0
    @State private var minutes = 15
    @State private var dayOffset: Int
    @State private var clockHour: Int
    @State private var clockMinute: Int
    @State private var sending = false
    @State private var outcomes: [String: HerdrPromptOutcome]?
    @FocusState private var editorFocused: Bool

    init(messaging: HerdrMessaging, draft: HerdrMessageDraft, hideAgents: Bool = false) {
        self.messaging = messaging
        initial = draft
        self.hideAgents = hideAgents
        _mode = State(initialValue: draft.delivery)
        let clock = Self.nextHalfHour()
        _dayOffset = State(initialValue: clock.dayOffset)
        _clockHour = State(initialValue: clock.hour)
        _clockMinute = State(initialValue: clock.minute)
    }

    private var dark: Bool { scheme == .dark }
    private var waiting: HerdrAgentHook? {
        guard let agent = initial.single else { return nil }
        guard let hook = messaging.armedHook(for: agent.id), hook.phase == .armed else {
            return nil
        }
        return hook
    }
    private var now: Date { Date() }
    private var canSend: Bool {
        HerdrAgentPrompt.normalized(text) != nil && !sending && scheduleIsValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
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
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(initial.title)
                .font(DashSkin.heading(17))
                .foregroundStyle(DashSkin.ink(dark))
                .presenterTextBlur(hideAgents && initial.single != nil, fontSize: 17)
            if let agent = initial.single {
                Text("\(HerdrKind.displayName(for: agent.kind)) · \(agent.status.title)")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            } else if let group = initial.group {
                let count = initial.recipients.count
                Text("\(count) \(count == 1 ? "agent" : "agents"). \(group.detail)")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            messageField
            if let waiting {
                Text("\(waiting.schedule.sendsPhrase(now: now)). Sending again replaces it.")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.accent(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if initial.single != nil {
                HerdrTimingChoice(mode: $mode)
                timing
            } else {
                recipientList
            }
            if let error = messaging.errorMessage {
                Text(error)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.red)
            }
        }
    }

    private var messageField: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Write a message")
                    .font(.system(size: UIScale.pt(12.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(.top, UIScale.pt(8))
                    .padding(.leading, UIScale.pt(12))
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(UIScale.pt(8))
        }
        .frame(height: UIScale.pt(96))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .strokeBorder(DashSkin.line(dark))
        }
        .accessibilityLabel("Message")
    }

    @ViewBuilder
    private var timing: some View {
        switch mode {
        case .now, .whenFinished:
            Text(mode.detail)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
        case .after:
            HerdrAfterPicker(hours: delayHours, minutes: delayMinutes, moment: afterMoment)
        case .at:
            HerdrAtPicker(
                dayOffset: $dayOffset, hour: $clockHour, minute: $clockMinute, now: now,
                moment: atMoment, passed: !scheduleIsValid)
        }
    }

    private var delayHours: Binding<Int> {
        Binding(get: { hours }, set: { setDelay(hours: $0, minutes: minutes) })
    }

    private var delayMinutes: Binding<Int> {
        Binding(get: { minutes }, set: { setDelay(hours: hours, minutes: $0) })
    }

    private var afterMoment: String {
        guard let when = scheduledAt else { return "" }
        return "Sends \(HerdrHookSchedule.moment(when, now: now))"
    }

    private var atMoment: String {
        guard let when = clockDate else { return "" }
        return HerdrHookSchedule.moment(when, now: now)
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
        guard initial.single != nil else { return "Send" }
        switch mode {
        case .now: return "Send"
        case .whenFinished: return "Send when it finishes"
        case .after:
            return "Send \(HerdrHookSchedule.delayPhrase(hours: hours, minutes: minutes))"
        case .at:
            guard let when = clockDate else { return "Send" }
            return "Send \(HerdrHookSchedule.clockText(when))"
        }
    }

    private var scheduleIsValid: Bool {
        switch mode {
        case .now, .whenFinished: true
        case .after: hours > 0 || minutes > 0
        case .at: (clockDate ?? .distantPast) > now
        }
    }

    private var scheduledAt: Date? {
        switch mode {
        case .after:
            let total = hours * 60 + minutes
            guard total > 0 else { return nil }
            return now.addingTimeInterval(TimeInterval(total * 60))
        case .at:
            return clockDate
        case .now, .whenFinished:
            return nil
        }
    }

    private var clockDate: Date? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: start) else {
            return nil
        }
        return calendar.date(bySettingHour: clockHour, minute: clockMinute, second: 0, of: day)
    }

    private func setDelay(hours: Int, minutes: Int) {
        let nextHours = min(23, max(0, hours))
        var nextMinutes = min(59, max(0, minutes))
        if nextHours == 0, nextMinutes == 0 { nextMinutes = 5 }
        self.hours = nextHours
        self.minutes = nextMinutes
    }

    private func submit() async {
        guard canSend, let text = HerdrAgentPrompt.normalized(text) else { return }
        sending = true
        defer { sending = false }
        if let agent = initial.single, mode != .now {
            let schedule: HerdrHookSchedule? =
                if mode == .whenFinished {
                    .whenFinished
                } else {
                    scheduledAt.map { .at($0) }
                }
            guard let schedule else { return }
            if await messaging.arm(text, for: agent, schedule: schedule) { dismiss() }
            return
        }
        let replies = await messaging.send(text, to: initial.recipients)
        if initial.single != nil, replies.values.allSatisfy(\.delivered) {
            dismiss()
            return
        }
        outcomes = replies
    }

    private static func nextHalfHour(from now: Date = Date()) -> (
        dayOffset: Int, hour: Int, minute: Int
    ) {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        var hour = calendar.component(.hour, from: now)
        let nextMinute: Int
        if minute < 30 {
            nextMinute = 30
        } else {
            nextMinute = 0
            hour += 1
        }
        if hour >= 24 { return (1, hour - 24, nextMinute) }
        return (0, hour, nextMinute)
    }
}
