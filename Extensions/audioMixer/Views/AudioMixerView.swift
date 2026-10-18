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
                    Text("Play audio in an app to control it here")
                        .font(bodyFont).foregroundStyle(notch ? .white.opacity(0.5) : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
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
                Button("Retry") { engine.retry() }
                Button("Open Settings") {
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
                LabeledContent("Lives in", value: "Notch Shelf")
                Text(
                    available
                        ? "Set the volume of each app from the shelf's audio tab."
                        : "Requires macOS 14.4 or later."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
        }
        .edithForm()
    }
}
