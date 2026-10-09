import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsRows: View {
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
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        Section("Tools") {
            LabeledContent(
                "Git",
                value: CLIToolEnvironment.executable(named: "git") == nil
                    ? "Not installed" : "Installed")
            LabeledContent(
                "GitHub CLI",
                value: CLIToolEnvironment.executable(named: "gh") == nil
                    ? "Optional, not installed" : "Installed")
        }

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
                    isOn: $includeForks)
                Toggle(
                    "Include archived repositories",
                    isOn: $includeArchived)
                Button("Refresh now") { refresh() }
                if let message {
                    Text(message).settingsCaption()
                }
            }

            Section("Schedule") {
                Picker(
                    "Refresh",
                    selection: $scheduleKind
                ) {
                    Text("Manually").tag(CodeStatsScheduleKind.manual.rawValue)
                    Text("Daily").tag(CodeStatsScheduleKind.daily.rawValue)
                    Text("Weekly").tag(CodeStatsScheduleKind.weekly.rawValue)
                }
                if scheduleKind == CodeStatsScheduleKind.weekly.rawValue {
                    Picker(
                        "Day",
                        selection: $weekday
                    ) {
                        ForEach(CodeStatsPreferences.weekdays, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                }
                if scheduleKind != CodeStatsScheduleKind.manual.rawValue {
                    Picker(
                        "Time", selection: $hour
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
        .pageTask(
            id:
                "\(folder):\(includeForks):\(includeArchived):\(scheduleKind):\(hour):\(weekday):\(identity.labels)"
        ) {
            await CodeStatsWorkerOperations.workflow?.settingsChanged()
        }
        .onDisappear {
            refreshTask?.cancel(); refreshTask = nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for your GitHub mirror"
        guard CodeStatsExecutionEnvironment.fixtureHome == nil else { return }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            folder = try CodeStatsPreferences.selectFolder(
                url.path, homeDirectory: CodeStatsExecutionEnvironment.home
            ).path
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
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                guard let workflow = CodeStatsWorkerOperations.workflow else {
                    throw ExtensionPeerError.unavailable
                }
                _ = try await workflow.start(.manual)
                try Task.checkCancellation()
                message = "Refreshing in the background."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
