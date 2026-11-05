import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct EmbeddedMusicSettings: View {
    var openLibrary: () -> Void = {}
    var done: (() -> Void)?
    @State private var tools = EmbeddedMusicTools.shared
    @State private var model: EmbeddedMusicSettingsModel
    @State private var openError: String?
    @Environment(\.compactLayout) private var compact

    private var formWidth: CGFloat { UIScale.pt(PageMetrics.formWidth) }
    private var formEdge: CGFloat {
        max(0, PageMetrics.gutter(compact) - PageMetrics.groupedFormInset)
    }

    init(
        model: EmbeddedMusicSettingsModel? = nil, done: (() -> Void)? = nil,
        openLibrary: @escaping () -> Void = {}
    ) {
        self.openLibrary = openLibrary
        self.done = done
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
                subtitle: "Library, streaming accounts and playback.",
                trailing: {
                    if let done {
                        Button("Done", action: done).buttonStyle(.edith(.secondary))
                            .keyboardShortcut(.cancelAction)
                    }
                }
            )
            .environment(\.pageColumnWidth, formWidth)
        } content: {
            Form {
                Section {
                    SettingsRow(
                        "Library tools",
                        subtitle:
                            "These tools save audio, videos, images and posts to your library."
                    ) {
                        Button("Check Again") { tools.refresh() }.buttonStyle(.edith(.secondary))
                    }
                    ForEach(EmbeddedMusicTools.names, id: \.self) { name in
                        SettingsRow(name, subtitle: EmbeddedMusicTools.purpose(of: name)) {
                            toolStatus(name)
                        }
                    }
                    if let error = tools.error {
                        SettingsErrorRow(
                            "A tool could not be installed", message: error,
                            retryTitle: "Check Again"
                        ) { tools.refresh() }
                    }
                } header: {
                    Text("Command-line tools")
                }
                Section("Library") {
                    SettingsRow(
                        "Streaming accounts",
                        subtitle: "Spotify and YouTube Music connect in Music."
                    ) {
                        Button("Connect in Music", action: openLibrary)
                            .buttonStyle(.edith(.secondary))
                    }
                    SettingsRow("Music folder", subtitle: "Where your tracks and downloads live.") {
                        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                            Button("Choose Folder...", action: chooseLibrary)
                                .buttonStyle(.edith(.secondary))
                            Button("Open in Finder") {
                                EmbeddedMusicRemote.shared.openLibrary()
                            }
                            .buttonStyle(.edith(.secondary))
                        }
                    }
                    if let openError {
                        SettingsNoticeRow(
                            "The folder could not be opened", message: openError,
                            symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    Toggle("Fade between tracks", isOn: model.boolean(.crossfade, \.crossfade))
                    if model.boolean(.crossfade, \.crossfade).wrappedValue {
                        SettingsSliderRow(
                            "Fade length",
                            subtitle: "How long the old track fades out as the next fades in.",
                            value: model.fadeLength, in: EmbeddedMusicFade.secondsRange,
                            readout: String(format: "%.1fs", model.fadeLength.wrappedValue))
                    }
                }
                .disabled(!model.loaded || model.closed)
                .opacity(model.loaded && !model.closed ? 1 : 0.5)
                EmbeddedMusicBarRows(model: model)
                if let error = model.error {
                    Section {
                        SettingsErrorRow("Settings could not be loaded", message: error) {
                            Task { await model.refresh() }
                        }
                    }
                }
            }
            .settingsForm()
            .padding(.horizontal, formEdge)
            .frame(maxWidth: formWidth, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .pageTask {
            await model.refresh(); tools.refresh()
        }
        .pageRefresh(interval: { .seconds(1) }) { await model.refresh() }
    }

    private func chooseLibrary() { EmbeddedMusicRemote.shared.chooseLibrary() }

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
        }
    }
}

struct EmbeddedMusicBarRows: View {
    @Bindable var model: EmbeddedMusicSettingsModel

    var body: some View {
        Section {
            Toggle(isOn: model.boolean(.barCollapsed, \.barCollapsed)) {
                Text("Collapse to a progress line")
                Text("The chevron at the right end of the bar toggles the collapsed state too.")
            }
            Toggle(
                "Hide when nothing is playing",
                isOn: model.boolean(.barAutoHide, \.barAutoHide))
        } header: {
            Text("Player bar")
        }
        .disabled(!model.loaded || model.closed)
        .opacity(model.loaded && !model.closed ? 1 : 0.5)
    }
}
