import EdithKit
import SwiftUI

struct AttentionFocusView: View {
    @Bindable var model: AttentionPageModel
    @State private var focusName = ""
    @State private var focusMinutes = 25
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let blocks = model.summary.focusBlocks.reversed()
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            AttentionPanel(
                model.activeFocus == nil ? "Start a focus session" : "Focusing",
                subtitle: "A named timer you control. Detected deep work below needs no timer."
            ) {
                if let focus = model.activeFocus {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(focus.startedAt)
                        let remaining = focus.plannedDuration - elapsed
                        VStack(spacing: UIScale.pt(12)) {
                            Text(focus.name.isEmpty ? "Focus" : focus.name)
                                .font(DashSkin.heading(22))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(
                                remaining >= 0
                                    ? AttentionFormat.clock(remaining)
                                    : "Overtime \(AttentionFormat.clock(abs(remaining)))"
                            )
                            .font(.system(size: UIScale.pt(30), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            ProgressView(value: min(1, elapsed / focus.plannedDuration))
                                .tint(AttentionPalette.kind(.focus, dark: dark))
                                .frame(maxWidth: UIScale.pt(420))
                            Button("Finish focus session") { model.stopFocus() }
                                .buttonStyle(.edith(.primary))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UIScale.pt(16))
                    }
                } else {
                    HStack(spacing: UIScale.pt(10)) {
                        TextField("What are you focusing on?", text: $focusName)
                            .textFieldStyle(.roundedBorder)
                        Picker("Duration", selection: $focusMinutes) {
                            ForEach([25, 45, 60, 90], id: \.self) { minutes in
                                Text("\(minutes)m").tag(minutes)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: UIScale.pt(220))
                        Button("Start") {
                            model.startFocus(
                                name: focusName, duration: TimeInterval(focusMinutes * 60))
                        }
                        .buttonStyle(.edith(.primary))
                    }
                }
            }
            AttentionPanel(
                "Deep work",
                subtitle:
                    "Stretches of at least \(Int(model.settings.focusBlockMinimum / 60)) productive minutes. Interruptions up to two minutes are tolerated."
            ) {
                if blocks.isEmpty {
                    AttentionEmpty(text: "No deep work block in this period yet", symbol: "brain.head.profile")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                            if index > 0 { Divider().opacity(0.5) }
                            HStack(spacing: UIScale.pt(12)) {
                                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                    Text(
                                        "\(block.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) to \(AttentionFormat.time(block.end))"
                                    )
                                    .font(.system(size: UIScale.pt(12.5), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    Text(block.topNames.joined(separator: ", "))
                                        .font(.system(size: UIScale.pt(11)))
                                        .foregroundStyle(DashSkin.inkSoft(dark))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: UIScale.pt(8))
                                VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                                    Text(AttentionFormat.duration(block.duration))
                                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(DashSkin.ink(dark))
                                    Text(
                                        block.interruptions == 0
                                            ? "uninterrupted"
                                            : "\(block.interruptions) interruptions · \(AttentionFormat.percent(block.focused, of: block.duration)) focused"
                                    )
                                    .font(.system(size: UIScale.pt(10)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                            }
                            .padding(.vertical, UIScale.pt(7))
                        }
                    }
                }
            }
            AttentionPanel("Focus sessions", subtitle: "Sessions you started from Edith or ed attention focus.") {
                if model.focusSessions.isEmpty {
                    AttentionEmpty(text: "No completed focus sessions in this period", symbol: "timer")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.focusSessions.enumerated()), id: \.element.id) {
                            index, session in
                            if index > 0 { Divider().opacity(0.5) }
                            HStack {
                                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                                    Text(session.name.isEmpty ? "Focus" : session.name)
                                        .font(.system(size: UIScale.pt(12.5)))
                                        .foregroundStyle(DashSkin.ink(dark))
                                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: UIScale.pt(10.5)))
                                        .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                                Spacer()
                                Text(
                                    AttentionFormat.duration(
                                        (session.endedAt ?? session.startedAt).timeIntervalSince(
                                            session.startedAt))
                                )
                                .font(.system(size: UIScale.pt(12), weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            }
                            .padding(.vertical, UIScale.pt(7))
                        }
                    }
                }
            }
        }
    }
}
