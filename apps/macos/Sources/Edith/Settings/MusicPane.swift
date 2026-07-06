import AppKit
import EdithKit
import SwiftUI

struct MusicPane: View {
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Music player", isOn: $enabled)
                    .pointerCursor()
                Text("Plays your local music folder from the menu bar panel, with media keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Music folder") {
                    Button("Open in Finder") {
                        try? FileManager.default.createDirectory(
                            at: Repo.musicDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Repo.musicDir)
                    }
                    .pointerCursor()
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
        .navigationTitle("Music")
    }
}
