import AppKit
import EdithKit
import SwiftUI

struct CodeStatsRows: View {
    @AppStorage(AppStorageKeys.Tabs.codeStatsEnabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.CodeStats.folder, store: SharedDefaults.store) private
        var folder = ""
    @AppStorage(AppStorageKeys.CodeStats.scheduleKind, store: SharedDefaults.store) private
        var scheduleKind = CodeStatsScheduleKind.manual.rawValue
    @AppStorage(AppStorageKeys.CodeStats.scheduleHour, store: SharedDefaults.store) private
        var hour = CodeStatsPreferences.defaultHour
    @AppStorage(AppStorageKeys.CodeStats.scheduleWeekday, store: SharedDefaults.store) private
        var weekday = CodeStatsPreferences.defaultWeekday
    @AppStorage(AppStorageKeys.CodeStats.includeForks, store: SharedDefaults.store) private
        var includeForks = false
    @AppStorage(AppStorageKeys.CodeStats.includeArchived, store: SharedDefaults.store) private
        var includeArchived = true
    @State private var identity = CodeStatsPreferences.identity(in: SharedDefaults.store)
    @State private var newIdentity = ""
    @State private var message: String?

    var body: some View {
        CLIToolStatusSection(tools: [.git, .githubCLI], extensionEnabled: enabled)

        Group {
            Section("Mirror") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.isEmpty ? "Not chosen" : folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose folder...") { chooseFolder() }
                    }
                }
                Text(
                    "Every repository you can reach on GitHub is kept here as a bare clone. It can take gigabytes, so an external drive works well; results stay visible while it is unplugged."
                )
                .settingsCaption()
                Toggle(
                    "Include forks",
                    isOn: $includeForks.configured(AppStorageKeys.CodeStats.includeForks))
                Toggle(
                    "Include archived repositories",
                    isOn: $includeArchived.configured(AppStorageKeys.CodeStats.includeArchived))
                Button("Refresh now") { refresh() }
                if let message {
                    Text(message).settingsCaption()
                }
            }

            Section("Schedule") {
                Picker(
                    "Refresh",
                    selection: $scheduleKind.configured(AppStorageKeys.CodeStats.scheduleKind)
                ) {
                    Text("Manually").tag(CodeStatsScheduleKind.manual.rawValue)
                    Text("Daily").tag(CodeStatsScheduleKind.daily.rawValue)
                    Text("Weekly").tag(CodeStatsScheduleKind.weekly.rawValue)
                }
                if scheduleKind == CodeStatsScheduleKind.weekly.rawValue {
                    Picker(
                        "Day",
                        selection: $weekday.configured(AppStorageKeys.CodeStats.scheduleWeekday)
                    ) {
                        ForEach(CodeStatsPreferences.weekdays, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                if scheduleKind != CodeStatsScheduleKind.manual.rawValue {
                    Picker(
                        "Time", selection: $hour.configured(AppStorageKeys.CodeStats.scheduleHour)
                    ) {
                        ForEach(CodeStatsPreferences.hours, id: \.self) { value in
                            Text(String(format: "%02d:00", value)).tag(value)
                        }
                    }
                }
                Text(
                    "A refresh missed while the Mac slept or the drive was unplugged runs once as soon as it can."
                )
                .settingsCaption()
            }

            Section("Identities") {
                ForEach(identity.labels, id: \.self) { label in
                    LabeledContent(label) {
                        Button("Remove") { remove(label) }
                    }
                }
                HStack {
                    TextField("Email or name fragment", text: $newIdentity)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(newIdentity.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(
                    "Commits whose author email matches, or whose name or email contains a fragment, count as yours. An empty list is filled from your GitHub profile."
                )
                .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for your GitHub mirror"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            folder = try CodeStatsPreferences.selectFolder(url.path).path
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func add() {
        CodeStatsPreferences.addIdentity(newIdentity, in: SharedDefaults.store)
        newIdentity = ""
        identity = CodeStatsPreferences.identity(in: SharedDefaults.store)
    }

    private func remove(_ label: String) {
        let value = label.hasPrefix("*") ? String(label.dropFirst().dropLast()) : label
        CodeStatsPreferences.removeIdentity(value, in: SharedDefaults.store)
        identity = CodeStatsPreferences.identity(in: SharedDefaults.store)
    }

    private func refresh() {
        message = "Starting a refresh..."
        Task {
            do {
                _ = try await CodeStatsAgentClient().start()
                message = "Refreshing in the background."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
