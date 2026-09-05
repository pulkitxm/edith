import EdithKit
import SwiftUI

struct AgentEventRow: View {
    let event: AgentEvent

    private var color: Color {
        switch event.level {
        case .info: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(event.message).textSelection(.enabled)
                LabeledContent("Category", value: event.category)
                LabeledContent("Event", value: event.id.uuidString)
                if let taskID = event.taskID {
                    LabeledContent("Task", value: taskID.uuidString).textSelection(.enabled)
                }
                if let duration = event.duration {
                    LabeledContent("Duration", value: String(format: "%.3f seconds", duration))
                }
            }
            .font(.system(size: UIScale.pt(11), design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(
                    systemName: event.level == .error
                        ? "exclamationmark.circle.fill" : "circle.fill"
                )
                .font(.system(size: event.level == .error ? 11 : 6))
                .foregroundStyle(color)
                .frame(width: 12)
                Text(event.date, format: .dateTime.hour().minute().second())
                    .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name)
                        .font(.system(size: UIScale.pt(11.5), weight: .medium, design: .monospaced))
                    Text(event.message)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(event.level == .error ? color : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if let duration = event.duration {
                    Text(String(format: "%.2fs", duration))
                        .font(.system(size: UIScale.pt(10.5), design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
    }
}
