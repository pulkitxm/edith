import EdithKit
import SwiftUI

struct CalendarPane: View {
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Today's schedule", isOn: $enabled)
                    .pointerCursor()
                Text("Shows today's calendar events in the menu bar panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calendar")
    }
}
