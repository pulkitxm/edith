import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct MusicSettings: View {
    var openLibrary: () -> Void = {}
    @State private var tools = MusicTools.shared
    @AppStorage(MusicFade.enabledKey, store: SharedDefaults.store) private var crossfade = true
    @AppStorage(MusicFade.secondsKey, store: SharedDefaults.store) private var crossfadeSeconds =
        MusicFade.defaultSeconds
    @State private var openError: String?

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Music settings",
                accessory: {
                    Text("Library, streaming accounts and playback.").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                })
        } content: {
            Form {
                Section("Library and playback") {
                    LabeledContent("Streaming accounts") {
                        Button("Connect in Music", action: openLibrary)
                    }
                    LabeledContent("Music folder") {
                        HStack {
                            Button("Choose folder...", action: chooseLibrary)
                            Button("Open in Finder") {
                                do {
                                    _ = try MusicLibraryOperationExecution.openLibrary();
                                    openError = nil
                                } catch { openError = error.localizedDescription }
                            }
                        }
                    }
                    if let openError { Text(openError).foregroundStyle(.red) }
                    Toggle("Fade between tracks", isOn: $crossfade)
                    if crossfade {
                        LabeledContent("Fade length") {
                            Text(String(format: "%.1fs", crossfadeSeconds)).monospacedDigit()
                        }
                        Slider(value: $crossfadeSeconds, in: MusicFade.secondsRange)
                        Text("How long the old track fades out while the next one fades in.").font(
                            .edithText(.caption)
                        ).foregroundStyle(.secondary)
                    }
                }
                Section("Download tools") {
                    Text(
                        "These tools save YouTube audio, videos, images and posts to your library."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                    ForEach(MusicTools.names, id: \.self) { name in
                        LabeledContent(name) {
                            if tools.installed.contains(name) {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if tools.installing == name {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Install") { tools.install(name) }.disabled(
                                    tools.installing != nil)
                            }
                        }
                    }
                    if let error = tools.error { Text(error).foregroundStyle(.red) }
                    Button("Check tools again") {
                        tools.refresh(); YoutubeDownloader.shared.checkAvailability()
                    }
                }
            }.edithForm()
        }
        .pageTask { tools.refresh() }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false;
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"; panel.message = "Choose your music folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try MusicFolderSelectionOperationExecution.select(url.path); openError = nil
        } catch { openError = error.localizedDescription }
    }
}
