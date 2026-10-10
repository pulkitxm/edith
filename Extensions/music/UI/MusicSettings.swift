import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct EmbeddedMusicSettings: View {
    var openLibrary: () -> Void = {}
    @State private var tools = EmbeddedMusicTools.shared
    @AppStorage(EmbeddedMusicFade.enabledKey, store: SharedDefaults.store) private var crossfade =
        true
    @AppStorage(EmbeddedMusicFade.secondsKey, store: SharedDefaults.store) private
        var crossfadeSeconds =
        EmbeddedMusicFade.defaultSeconds
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
                                EmbeddedMusicRemote.shared.openLibrary()
                            }
                        }
                    }
                    if let openError { Text(openError).foregroundStyle(.red) }
                    Toggle("Fade between tracks", isOn: $crossfade)
                    if crossfade {
                        LabeledContent("Fade length") {
                            Text(String(format: "%.1fs", crossfadeSeconds)).monospacedDigit()
                        }
                        Slider(value: $crossfadeSeconds, in: EmbeddedMusicFade.secondsRange)
                        Text("How long the old track fades out while the next one fades in.").font(
                            .edithText(.caption)
                        ).foregroundStyle(.secondary)
                    }
                }
                Section("Download tools") {
                    Text(
                        "These tools save YouTube audio, videos, images and posts to your library."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                    ForEach(EmbeddedMusicTools.names, id: \.self) { name in
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
                        tools.refresh();
                    }
                }
            }.edithForm()
        }
        .onChange(of: crossfade) {
            EmbeddedMusicRemote.shared.send(.crossfade, value: crossfade ? 1 : 0)
        }
        .onChange(of: crossfadeSeconds) {
            EmbeddedMusicRemote.shared.send(.fadeLength, value: crossfadeSeconds)
        }
        .pageTask { tools.refresh() }
    }

    private func chooseLibrary() { EmbeddedMusicRemote.shared.chooseLibrary() }
}
