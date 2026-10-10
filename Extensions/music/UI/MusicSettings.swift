import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct EmbeddedMusicSettings: View {
    var openLibrary: () -> Void = {}
    @State private var tools = EmbeddedMusicTools.shared
    @State private var model: EmbeddedMusicSettingsModel
    @State private var openError: String?

    init(model: EmbeddedMusicSettingsModel? = nil, openLibrary: @escaping () -> Void = {}) {
        self.openLibrary = openLibrary
        _model = State(
            initialValue: model
                ?? EmbeddedMusicSettingsModel { operation, payload in
                    try await EmbeddedMusicRemote.shared.dataRequest(operation, payload: payload)
                })
    }

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
                    Toggle("Fade between tracks", isOn: model.boolean(.crossfade, \.crossfade))
                    if model.boolean(.crossfade, \.crossfade).wrappedValue {
                        LabeledContent("Fade length") {
                            Text(String(format: "%.1fs", model.fadeLength.wrappedValue))
                                .monospacedDigit()
                        }
                        Slider(value: model.fadeLength, in: EmbeddedMusicFade.secondsRange)
                        Text("How long the old track fades out while the next one fades in.").font(
                            .edithText(.caption)
                        ).foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.loaded || model.closed)
                .opacity(model.loaded && !model.closed ? 1 : 0.5)
                EmbeddedMusicBarRows(model: model)
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.edithText(.caption))
                    Button("Try again") { Task { await model.refresh() } }
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
        .pageTask {
            await model.refresh(); tools.refresh()
        }
        .pageRefresh(interval: { .seconds(1) }) { await model.refresh() }
    }

    private func chooseLibrary() { EmbeddedMusicRemote.shared.chooseLibrary() }
}

struct EmbeddedMusicBarRows: View {
    @Bindable var model: EmbeddedMusicSettingsModel

    var body: some View {
        Section("Player bar") {
            Toggle(
                "Collapse to a progress line",
                isOn: model.boolean(.barCollapsed, \.barCollapsed))
            Toggle(
                "Hide when nothing is playing",
                isOn: model.boolean(.barAutoHide, \.barAutoHide))
            Text("The chevron at the right end of the bar toggles the collapsed state too.")
                .font(.edithText(.caption))
                .foregroundStyle(.secondary)
        }
        .disabled(!model.loaded || model.closed)
        .opacity(model.loaded && !model.closed ? 1 : 0.5)
    }
}
