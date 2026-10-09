import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DownloadsSettings: View {
    let downloader: YoutubeDownloader
    @State private var tools = DownloadsTools.shared
    @AppStorage(AppStorageKeys.Music.downloadKind, store: SharedDefaults.store) private
        var downloadKind = DownloadKind.post.rawValue
    @State private var folderError: String?

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Download settings",
                accessory: {
                    Text("Save videos, audio, photos and posts.").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                })
        } content: {
            Form {
                Section("Downloads") {
                    EdithSegmentedPicker(
                        "Default format", selection: $downloadKind,
                        options: DownloadKind.allCases.map(\.rawValue),
                        label: { DownloadKind(rawValue: $0)?.title ?? $0 })
                    Text(
                        "Audio uses your chosen audio folder. Other media defaults to Downloads/Edith. Every request can choose its own output folder."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                    LabeledContent("Audio folder") {
                        Button("Choose folder...", action: chooseAudioFolder)
                    }
                    Text(DownloadsStorage.audioDirectory.path).font(.edithText(.caption))
                        .textSelection(.enabled)
                    if let folderError { Text(folderError).foregroundStyle(.red) }
                }
                Section("Download tools") {
                    Text(
                        "Install tools explicitly when needed. Downloads never installs them in the background."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                    ForEach(DownloadsTools.names, id: \.self) { name in
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
                        tools.refresh(); downloader.checkAvailability()
                    }
                }
            }.edithForm()
        }.pageTask { tools.refresh() }
    }
    private func chooseAudioFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where audio downloads are saved"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DownloadsStorage.setAudioDirectory(url)
        folderError = nil
    }
}
