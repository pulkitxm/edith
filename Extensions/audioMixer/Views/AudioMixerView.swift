import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@available(macOS 14.4, *)
@MainActor
struct AudioMixerView: View {
    @State private var engine: any AudioMixerPresenting
    private let monitorsWhileVisible: Bool
    private let notch: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(engine: any AudioMixerPresenting, monitorsWhileVisible: Bool = true, notch: Bool = false) {
        self.monitorsWhileVisible = monitorsWhileVisible
        self.notch = notch
        _engine = State(initialValue: engine)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let error = engine.errorMessage {
                    errorView(error)
                }
                if engine.apps.isEmpty, engine.errorMessage == nil {
                    emptyView
                } else {
                    ForEach(engine.apps) { app in
                        row(app)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .tint(notch ? Color.accentColor : nil)
        .environment(\.colorScheme, notch ? .dark : colorScheme)
        .onAppear { if monitorsWhileVisible { engine.viewAppeared() } }
        .onDisappear { if monitorsWhileVisible { engine.viewDisappeared() } }
    }

    @ViewBuilder private var emptyView: some View {
        if notch {
            VStack(spacing: 4) {
                Text("Nothing is playing sound right now")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                Text("Start music or a video and its volume slider appears here.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            PageEmptyState(
                symbolName: "speaker.wave.2",
                title: "Nothing is playing sound right now",
                message:
                    "Apps show up here while they make sound. Start music or a video, then set each app's volume separately.",
                footnote: "Setting an app back to 100 restores its normal volume.")
        }
    }

    private var bodyFont: Font { notch ? .system(size: 12) : .edithText(.body) }

    private func row(_ app: MixerApp) -> some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(notch ? .white.opacity(0.7) : .secondary)
                    .frame(width: 22, height: 22)
            }
            Text(app.name).font(bodyFont).foregroundStyle(notch ? .white : .primary).lineLimit(1)
                .frame(width: 80, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(app.volume) },
                    set: { engine.setVolume(app, Float($0)) }), in: 0...1
            )
            .controlSize(.mini)
            Text("\(Int(app.volume * 100))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(notch ? .white.opacity(0.6) : .secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(notch ? .system(size: 10.5) : .edithText(.caption))
            .foregroundStyle(.orange)
            HStack(spacing: 10) {
                Button("Try again") { engine.retry() }
                Button("Open Privacy settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .buttonStyle(.edith(.borderless))
            .font(
                notch
                    ? .system(size: 10, weight: .semibold) : .edithText(.caption).weight(.semibold)
            )
            .foregroundStyle(notch ? .white.opacity(0.8) : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AudioMixerSettingsPage: View {
    private var available: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Mixer") {
                LabeledContent("Lives in", value: "Notch Shelf, Audio tab")
                Text(
                    available
                        ? "Open the notch and choose Audio to set the volume of each app that is playing sound. macOS asks for audio access the first time. Turn the mixer on under Notch Shelf settings."
                        : "Per-app volume needs macOS 14.4 or later, so it is unavailable on this Mac."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
        }
        .edithForm()
    }
}
