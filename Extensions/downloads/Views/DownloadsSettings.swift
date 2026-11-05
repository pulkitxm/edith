import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DownloadsSettings: View {
    let downloader: YoutubeDownloader
    var done: (() -> Void)?
    private var tools: DownloadsTools { downloader.tools }
    @AppStorage(AppStorageKeys.Music.downloadKind, store: SharedDefaults.store) private
        var downloadKind = DownloadKind.post.rawValue

    var body: some View {
        PageWorkspace {
            PageHeader(
                "Download settings",
                trailing: {
                    if let done {
                        Button("Done", action: done).buttonStyle(.edith(.secondary))
                            .keyboardShortcut(.cancelAction)
                    }
                },
                accessory: {
                    Text("Save videos, audio, photos and posts.").font(.edithText(.caption))
                        .foregroundStyle(.secondary)
                })
        } content: {
            Form {
                Section {
                    ForEach(DownloadsTools.names, id: \.self) { name in
                        SettingsRow(name, subtitle: DownloadsTools.purpose(of: name)) {
                            toolStatus(name)
                        }
                    }
                    if let error = tools.error {
                        SettingsErrorRow(
                            "A tool could not be installed", message: error,
                            retryTitle: "Check Again", retry: checkAgain)
                    }
                } header: {
                    Text("Download tools")
                } footer: {
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: UIScale.pt(PageMetrics.cardSpacing)
                    ) {
                        Text("Free command line tools. Only yt-dlp is required.")
                        Spacer(minLength: 0)
                        Button("Check Again", action: checkAgain).buttonStyle(.edith(.toolbar))
                    }
                }
                Section {
                    Picker("Default format", selection: $downloadKind) {
                        ForEach(DownloadKind.allCases, id: \.rawValue) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text(
                        "Audio saves to Music. Everything else saves to Downloads/Edith. Install gallery-dl for images and carousels."
                    )
                }
            }.settingsForm()
        }.pageTask {
            checkAgain()
        }
        .onChange(of: downloadKind) { _, value in
            if let kind = DownloadKind(rawValue: value) { downloader.setPreferredKind(kind) }
        }
    }

    @ViewBuilder
    private func toolStatus(_ name: String) -> some View {
        if tools.installed.contains(name) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if tools.installing == name {
            SkeletonBlock(width: 64, height: 12, corner: 4)
                .accessibilityLabel("Installing \(name)")
        } else {
            Button("Install") { tools.install(name) }
                .buttonStyle(.edith(.secondary))
                .disabled(tools.installing != nil)
                .help(
                    tools.installing != nil
                        ? "Wait for the current install to finish" : "Install \(name)")
        }
    }

    private func checkAgain() {
        tools.refresh()
        downloader.checkAvailability()
    }
}
