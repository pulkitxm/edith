import EdithKit
import SwiftUI

struct UpdateSchedulePanel: View {
    let updater: UpdaterModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingCustom = false
    @State private var customSeconds = ""
    @State private var clampNotice: String?
    @FocusState private var customFocused: Bool

    private var showsCustomField: Bool {
        editingCustom || !UpdateCheckInterval.isPreset(updater.checkInterval)
    }

    private var interval: Binding<TimeInterval> {
        Binding(
            get: { showsCustomField ? UpdateCheckInterval.customTag : updater.checkInterval },
            set: { value in
                guard value != UpdateCheckInterval.customTag else {
                    customSeconds = String(Int(updater.checkInterval))
                    clampNotice = nil
                    editingCustom = true
                    customFocused = true
                    return
                }
                editingCustom = false
                clampNotice = nil
                updater.checkInterval = value
            })
    }

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 })
    }

    private func commitCustomSeconds() {
        let typed = customSeconds.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let entered = TimeInterval(typed) else {
            customSeconds = String(Int(updater.checkInterval))
            clampNotice = nil
            return
        }
        let clamped = UpdateCheckInterval.clamp(entered)
        updater.checkInterval = clamped
        customSeconds = String(Int(clamped))
        clampNotice = UpdateCheckInterval.clampNotice(entered: entered, applied: clamped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(20)) {
                    schedule
                    Divider()
                    history
                }
                .padding(UIScale.pt(20))
            }
            Divider()
            footer
        }
        .frame(width: UIScale.pt(540), height: UIScale.pt(620))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text("Update checks")
                .font(.system(size: UIScale.pt(17), weight: .semibold))
            Text(countSummary)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(20))
    }

    private var countSummary: String {
        let automatic = updater.automaticCheckCount
        let total = updater.checkHistory.count
        guard total > 0 else { return "No checks recorded yet" }
        let auto = automatic == 1 ? "1 automatic check" : "\(automatic) automatic checks"
        return "\(auto) of \(total) recorded"
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Schedule")
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .foregroundStyle(.secondary)
            Toggle("Check automatically", isOn: automaticChecks)
                .pointerCursor()
            HStack(spacing: UIScale.pt(10)) {
                Text("Frequency")
                Picker("", selection: interval) {
                    ForEach(UpdateCheckInterval.choices) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                    Divider()
                    Text("Custom…").tag(UpdateCheckInterval.customTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .pointerCursor()
                .frame(width: UIScale.pt(190))
                Spacer()
            }
            .disabled(!updater.automaticallyChecksForUpdates)
            if showsCustomField { customField }
            HStack(spacing: UIScale.pt(10)) {
                Button("Run a background check now", action: updater.checkForUpdatesInBackground)
                    .pointerCursor()
                    .disabled(!updater.canCheckForUpdates)
                Text("uses the scheduled check path")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.tertiary)
            }
            if let next = nextCheckDescription {
                Text(next)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var rangeHint: String {
        let low = Int(UpdateCheckInterval.minimumSeconds)
        let high = Int(UpdateCheckInterval.maximumSeconds)
        return "Between \(low) and \(high) seconds."
    }

    private var noticeStyle: AnyShapeStyle {
        clampNotice == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange)
    }

    private var customField: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(8)) {
                TextField("", text: $customSeconds)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: UIScale.pt(110))
                    .focused($customFocused)
                    .onSubmit(commitCustomSeconds)
                    .onChange(of: customFocused) { _, focused in
                        if !focused { commitCustomSeconds() }
                    }
                Text("seconds")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(UpdateCheckInterval.describe(updater.checkInterval))
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.tertiary)
            }
            Text(clampNotice ?? rangeHint)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(noticeStyle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!updater.automaticallyChecksForUpdates)
    }

    private var nextCheckDescription: String? {
        guard updater.automaticallyChecksForUpdates else { return "Automatic checks are off" }
        guard let last = updater.lastUpdateCheckDate else { return nil }
        let next = last.addingTimeInterval(updater.checkInterval)
        return "Next check around \(next.formatted(.dateTime.month().day().hour().minute()))"
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                Text("History")
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !updater.checkHistory.isEmpty {
                    Button("Clear", action: updater.clearCheckHistory)
                        .buttonStyle(.link)
                        .font(.system(size: UIScale.pt(11)))
                        .pointerCursor()
                }
            }
            if updater.checkHistory.isEmpty {
                Text("Checks appear here once Edith has looked for an update.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(updater.checkHistory.enumerated()), id: \.element.id) {
                        index, entry in
                        if index > 0 { Divider() }
                        row(entry)
                    }
                }
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
            }
        }
    }

    private func row(_ record: UpdateCheckRecord) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            Circle()
                .fill(color(for: record.outcome))
                .frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text(record.date.formatted(.dateTime.month().day().hour().minute()))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .frame(width: UIScale.pt(140), alignment: .leading)
            Text(record.summary)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: UIScale.pt(8))
            Text(record.kind.label)
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(9))
    }

    private func color(for outcome: UpdateCheckRecord.Outcome) -> Color {
        switch outcome {
        case .upToDate: return .secondary
        case .updateFound: return .accentColor
        case .failed: return .red
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
        }
        .padding(UIScale.pt(16))
    }
}
