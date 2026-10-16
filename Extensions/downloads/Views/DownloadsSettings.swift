import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DownloadsSettings: View {
    let downloader: YoutubeDownloader
    private var tools: DownloadsTools { downloader.tools }
    @AppStorage(AppStorageKeys.Music.downloadKind, store: SharedDefaults.store) private
        var downloadKind = DownloadKind.post.rawValue

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
                Section("Download tools") {
                    Text(
                        "Add the tools required for the media you want to save."
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
                Section("Downloads") {
                    Picker("Default format", selection: $downloadKind) {
                        ForEach(DownloadKind.allCases, id: \.rawValue) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                    Text(
                        "Save videos, photos and entire posts. Install gallery-dl above for images and carousels. Audio defaults to Music; other media defaults to Downloads/Edith."
                    ).font(.edithText(.caption)).foregroundStyle(.secondary)
                    Button("Open Downloads") { ExtensionPresentation.showWindow() }
                }
            }.edithForm()
        }.pageTask {
            tools.refresh(); downloader.checkAvailability()
        }
        .onChange(of: downloadKind) { _, value in
            if let kind = DownloadKind(rawValue: value) { downloader.setPreferredKind(kind) }
        }
    }
}
