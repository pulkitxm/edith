import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@available(macOS 14.4, *)
@MainActor
struct AudioMixerView: View {
    @State private var engine: MixerEngine
    private let monitorsWhileVisible: Bool

    init(engine: MixerEngine, monitorsWhileVisible: Bool = true) {
        self.monitorsWhileVisible = monitorsWhileVisible
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
                        .font(.edithText(.body)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(engine.apps) { app in
                        row(app)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onAppear { if monitorsWhileVisible { engine.viewAppeared() } }
        .onDisappear { if monitorsWhileVisible { engine.viewDisappeared() } }
    }

    private func row(_ app: MixerApp) -> some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            Text(app.name).font(.edithText(.body)).foregroundStyle(.primary).lineLimit(1)
                .frame(width: 80, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(app.volume) },
                    set: { engine.setVolume(app, Float($0)) }), in: 0...1
            )
            .controlSize(.mini)
            Text("\(Int(app.volume * 100))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.edithText(.caption))
            .foregroundStyle(.orange)
            HStack(spacing: 10) {
                Button("Retry") { engine.retry() }
                Button("Open Settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .buttonStyle(.edith(.borderless))
            .font(.edithText(.caption).weight(.semibold))
            .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
