import EdithKit
import SwiftUI

struct TimeLapseRecordingRow: View {
    let recording: TimeLapseRecording
    let duration: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(12)) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(recording.session.settings.mode.rawValue)
                        .font(.edithText(.callout)).fontWeight(.medium)
                    Text(
                        recording.session.startedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: UIScale.pt(8))
                VStack(alignment: .trailing, spacing: UIScale.pt(4)) {
                    Text(duration).font(.edithText(.callout)).monospacedDigit()
                    if recording.session.endedAt == nil {
                        Text("Interrupted").font(.edithText(.caption)).foregroundStyle(.orange)
                    }
                }
            }
            .padding(UIScale.pt(3))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.edith(.row, selected: selected))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
