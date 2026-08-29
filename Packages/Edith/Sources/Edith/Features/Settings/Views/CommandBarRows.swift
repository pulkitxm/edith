import AppKit
import EdithKit
import SwiftUI

struct CommandBarRows: View {
    @AppStorage(AppStorageKeys.CommandBar.enabled, store: SharedDefaults.store) private
        var enabled =
        false
    @AppStorage(AppStorageKeys.CommandBar.showApplications, store: SharedDefaults.store) private
        var showApplications = true
    @AppStorage(AppStorageKeys.CommandBar.learnRanking, store: SharedDefaults.store) private
        var learnRanking = true
    @AppStorage(AppStorageKeys.CommandBar.registrationStatus, store: SharedDefaults.store) private
        var registrationStatus = 0
    @AppStorage(AppStorageKeys.CommandBar.fileScopes, store: SharedDefaults.store) private
        var fileScopes = ""
    @AppStorage(AppStorageKeys.CommandBar.pinnedResults, store: SharedDefaults.store) private
        var pinnedResults = ""
    @AppStorage(AppStorageKeys.CommandBar.hiddenResults, store: SharedDefaults.store) private
        var hiddenResults = ""
    @AppStorage(AppStorageKeys.CommandBar.resultShortcuts, store: SharedDefaults.store) private
        var resultShortcuts = ""

    var body: some View {
        Group {
            Section {
                LabeledContent {
                    HotKeyRecorderControl(keyPrefix: "commandBarHotKey", defaultLabel: "⌥Space")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Command Bar hotkey")
                        InfoDot("Opens the palette over the application you are using.")
                    }
                }
                Toggle(
                    "Show installed applications",
                    isOn: $showApplications.configured(AppStorageKeys.CommandBar.showApplications))
                Toggle(
                    "Learn result ranking",
                    isOn: $learnRanking.configured(AppStorageKeys.CommandBar.learnRanking))
                if registrationStatus != 0 {
                    Label(
                        "This shortcut is already in use. Record a different shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                }
            } header: {
                Text("Palette")
            } footer: {
                Text(
                    "Option-Space is the default and is separate from Edith's global panel shortcut."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                ForEach(CommandBarPreferences.decodeList(fileScopes), id: \.self) { path in
                    LabeledContent {
                        Button {
                            removeFolder(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.edith(.borderless))
                        .help("Remove folder")
                    } label: {
                        Label(
                            URL(fileURLWithPath: path).lastPathComponent,
                            systemImage: "folder.fill")
                        Text(path)
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Button("Add Search Folder…") {
                    chooseFolders()
                }
            } header: {
                Text("File Search")
            } footer: {
                Text(
                    "Uses the metadata index already maintained by macOS. Edith does not build or store a private file index."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                LabeledContent("Pinned results") {
                    Text("\(CommandBarPreferences.decodeList(pinnedResults).count)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hidden results") {
                    Text("\(CommandBarPreferences.decodeSet(hiddenResults).count)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Assigned shortcuts") {
                    Text("\(CommandBarPreferences.decodeShortcuts(resultShortcuts).count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Clear Pins") {
                        pinnedResults = ""
                        settingsChanged()
                    }
                    .disabled(pinnedResults.isEmpty)
                    Button("Show Hidden Results") {
                        hiddenResults = ""
                        settingsChanged()
                    }
                    .disabled(hiddenResults.isEmpty)
                    Button("Clear Result Shortcuts") {
                        resultShortcuts = ""
                        settingsChanged()
                    }
                    .disabled(resultShortcuts.isEmpty)
                }
            } header: {
                Text("Results")
            } footer: {
                Text(
                    "Control-click a result to pin it, hide it, or assign one of nine global shortcuts."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                LabeledContent("Search processing") {
                    Text("On this Mac")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Saved ranking data") {
                    Text("Result IDs and usage counts")
                        .foregroundStyle(.secondary)
                }
                Button("Clear learned ranking", role: .destructive) {
                    SharedDefaults.store.removeObject(forKey: AppStorageKeys.CommandBar.usage)
                    IPC.post(IPC.Name.settingsChanged)
                }
                .disabled(!learnRanking)
            } header: {
                Text("Privacy")
            } footer: {
                Text(
                    "Query and selected text are never saved. Clipboard, file, emoji, calculation, conversion, and application searches stay on this Mac."
                )
                .font(.system(size: UIScale.pt(10)))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let selected = panel.urls.map { url in
            CommandBarFileSearchSupport.abbreviating(
                url.standardizedFileURL.path, homeDirectory: home)
        }
        fileScopes = CommandBarPreferences.encodeList(
            CommandBarPreferences.decodeList(fileScopes) + selected)
        settingsChanged()
    }

    private func removeFolder(_ path: String) {
        fileScopes = CommandBarPreferences.encodeList(
            CommandBarPreferences.decodeList(fileScopes).filter { $0 != path })
        settingsChanged()
    }

    private func settingsChanged() {
        IPC.post(IPC.Name.settingsChanged)
    }
}
