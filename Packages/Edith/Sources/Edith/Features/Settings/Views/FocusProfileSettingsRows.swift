import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct FocusProfileSettingsRows: View {
    @AppStorage(AppStorageKeys.Focus.enabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.Tabs.calendarEnabled, store: SharedDefaults.store) private
        var calendarEnabled = false
    @State private var document = FocusDocument()
    @State private var scenes: [AutomationScene] = []
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    private let storage = FocusStorage()

    var body: some View {
        Group {
            Section("Profiles") {
                if document.profiles.isEmpty {
                    Text(
                        "Profiles compose reusable scenes and restore captured state when they end."
                    )
                    .settingsCaption()
                } else {
                    Picker("Edit profile", selection: $selectedID) {
                        ForEach(document.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    if selectedIndex != nil { profileEditor }
                }
                HStack {
                    Button("Create Profile") { createProfile() }
                    Spacer()
                    if let profile = selectedProfile {
                        Button("Start Now") {
                            IPC.post(
                                IPC.Name.requestFocusAction,
                                userInfo: [
                                    "action": "start", "profile": profile.id.uuidString,
                                    "origin": "app",
                                ])
                        }
                        .disabled(!profile.isEnabled)
                    }
                }
            }
            Section("Meeting Mode") {
                Toggle("Activate from Edith Calendar", isOn: meetingBinding(\.isEnabled))
                Picker("Meeting profile", selection: meetingBinding(\.profileID)) {
                    Text("Choose a profile").tag(Optional<UUID>.none)
                    ForEach(document.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                Picker("Meeting start scene", selection: meetingSceneBinding(\.startSceneIDs)) {
                    sceneChoices
                }
                Picker("Meeting end scene", selection: meetingSceneBinding(\.endSceneIDs)) {
                    sceneChoices
                }
                Toggle("Busy events only", isOn: meetingBinding(\.busyEventsOnly))
                Toggle("Require a join link", isOn: meetingBinding(\.requiresJoinLink))
                Stepper(
                    "Minimum duration: \(document.meeting.minimumDurationMinutes) minutes",
                    value: meetingBinding(\.minimumDurationMinutes), in: 5...120, step: 5)
                TextField(
                    "Excluded title terms, comma separated",
                    text: meetingTermsBinding(\.excludedTitleTerms))
                TextField(
                    "Excluded calendar ids, comma separated",
                    text: meetingTermsBinding(\.excludedCalendarIdentifiers))
                Text(
                    calendarEnabled
                        ? "Event details stay local. History records the profile and result, not meeting titles."
                        : "Enable Edith Calendar and grant Calendar access before turning on detection."
                )
                .settingsCaption()
            }
            Section("Status and recovery") {
                Toggle(
                    "Show active focus in the menu bar", isOn: documentBinding(\.showsStatusItem))
                Text(
                    "Stopping, disabling Edith, quitting, or recovering an expired session runs rollback scenes and restores captured settings and app state."
                )
                .settingsCaption()
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onAppear { load() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.focusProfilesChanged)
        ) { _ in load() }
    }

    @ViewBuilder private var profileEditor: some View {
        TextField("Name", text: profileBinding(\.name))
        Toggle("Enabled", isOn: profileBinding(\.isEnabled))
        Picker("Start scene", selection: sceneBinding(\.sceneIDs)) { sceneChoices }
        Picker("Window layout hook", selection: profileBinding(\.windowLayoutSceneID)) {
            sceneChoices
        }
        Picker("Rollback scene", selection: sceneBinding(\.rollbackSceneIDs)) { sceneChoices }
        TextField("Launch app bundle ids", text: appListBinding(\.launchApplicationIDs))
        TextField("Quit app bundle ids", text: appListBinding(\.quitApplicationIDs))
        TextField("Excluded foreground apps", text: setBinding(\.excludedBundleIdentifiers))
        TextField("macOS Focus name for guidance", text: optionalTextBinding(\.focusModeName))
        Toggle("Notify on start and restore", isOn: profileBinding(\.notifies))
        Picker("Global shortcut", selection: shortcutBinding) {
            Text("None").tag("")
            ForEach(1...5, id: \.self) { Text("⌃⌥⌘\($0)").tag("⌃⌥⌘\($0)") }
        }
        Toggle("Timed by default", isOn: timedBinding)
        if let duration = selectedProfile?.defaultDurationMinutes {
            Stepper(
                "Default duration: \(duration) minutes",
                value: optionalIntBinding(\.defaultDurationMinutes, fallback: 50), in: 5...480,
                step: 5)
        }
        Button("Delete Profile", role: .destructive) { deleteProfile() }
    }

    @ViewBuilder private var sceneChoices: some View {
        Text("None").tag(Optional<UUID>.none)
        ForEach(scenes) { scene in Text(scene.name).tag(Optional(scene.id)) }
    }

    private var selectedIndex: Int? {
        document.profiles.firstIndex { $0.id == selectedID }
    }

    private var selectedProfile: FocusProfile? {
        selectedIndex.map { document.profiles[$0] }
    }

    private func profileBinding<Value>(_ keyPath: WritableKeyPath<FocusProfile, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { selectedProfile![keyPath: keyPath] },
            set: { value in
                guard let index = selectedIndex else { return }
                document.profiles[index][keyPath: keyPath] = value
                save()
            })
    }

    private func documentBinding<Value>(_ keyPath: WritableKeyPath<FocusDocument, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { document[keyPath: keyPath] },
            set: {
                document[keyPath: keyPath] = $0; save()
            })
    }

    private func meetingBinding<Value>(
        _ keyPath: WritableKeyPath<FocusMeetingConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { document.meeting[keyPath: keyPath] },
            set: {
                document.meeting[keyPath: keyPath] = $0; save()
            })
    }

    private func sceneBinding(_ keyPath: WritableKeyPath<FocusProfile, [UUID]>) -> Binding<UUID?> {
        Binding(
            get: { selectedProfile?[keyPath: keyPath].first },
            set: { profileBinding(keyPath).wrappedValue = $0.map { [$0] } ?? [] })
    }

    private func appListBinding(_ keyPath: WritableKeyPath<FocusProfile, [String]>) -> Binding<
        String
    > {
        Binding(
            get: { selectedProfile?[keyPath: keyPath].joined(separator: ", ") ?? "" },
            set: { profileBinding(keyPath).wrappedValue = terms($0) })
    }

    private func setBinding(_ keyPath: WritableKeyPath<FocusProfile, Set<String>>) -> Binding<
        String
    > {
        Binding(
            get: { selectedProfile?[keyPath: keyPath].sorted().joined(separator: ", ") ?? "" },
            set: { profileBinding(keyPath).wrappedValue = Set(terms($0)) })
    }

    private func meetingTermsBinding(
        _ keyPath: WritableKeyPath<FocusMeetingConfiguration, Set<String>>
    ) -> Binding<String> {
        Binding(
            get: { document.meeting[keyPath: keyPath].sorted().joined(separator: ", ") },
            set: { meetingBinding(keyPath).wrappedValue = Set(terms($0)) })
    }

    private func meetingSceneBinding(
        _ keyPath: WritableKeyPath<FocusMeetingConfiguration, [UUID]>
    ) -> Binding<UUID?> {
        Binding(
            get: { document.meeting[keyPath: keyPath].first },
            set: { meetingBinding(keyPath).wrappedValue = $0.map { [$0] } ?? [] })
    }

    private func optionalTextBinding(
        _ keyPath: WritableKeyPath<FocusProfile, String?>
    ) -> Binding<String> {
        Binding(
            get: { selectedProfile?[keyPath: keyPath] ?? "" },
            set: { profileBinding(keyPath).wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private var shortcutBinding: Binding<String> {
        Binding(
            get: { selectedProfile?.shortcut?.label ?? "" },
            set: { label in
                let number = Int(label.last.map(String.init) ?? "")
                let keyCodes = [
                    1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5,
                ]
                profileBinding(\.shortcut).wrappedValue = number.flatMap { keyCodes[$0] }.map {
                    AutomationShortcut(
                        keyCode: Int($0), modifiers: controlKey | optionKey | cmdKey, label: label)
                }
            })
    }

    private var timedBinding: Binding<Bool> {
        Binding(
            get: { selectedProfile?.defaultDurationMinutes != nil },
            set: { profileBinding(\.defaultDurationMinutes).wrappedValue = $0 ? 50 : nil })
    }

    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<FocusProfile, Int?>, fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: { selectedProfile?[keyPath: keyPath] ?? fallback },
            set: { profileBinding(keyPath).wrappedValue = $0 })
    }

    private func terms(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func createProfile() {
        let profile = FocusProfile(
            name: "Deep work", sceneIDs: scenes.first.map { [$0.id] } ?? [],
            defaultDurationMinutes: 50)
        document.profiles.append(profile)
        selectedID = profile.id
        save()
    }

    private func deleteProfile() {
        guard let index = selectedIndex else { return }
        let id = document.profiles[index].id
        document.profiles.remove(at: index)
        if document.meeting.profileID == id { document.meeting.profileID = nil }
        selectedID = document.profiles.first?.id
        save()
    }

    private func load() {
        do {
            document = try storage.load()
            scenes = (try? AutomationStorage().load().scenes) ?? []
            if selectedID == nil || selectedIndex == nil {
                selectedID = document.profiles.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            try storage.save(document)
            errorMessage = nil
            IPC.post(IPC.Name.focusProfilesChanged)
            IPC.post(IPC.Name.settingsChanged)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
