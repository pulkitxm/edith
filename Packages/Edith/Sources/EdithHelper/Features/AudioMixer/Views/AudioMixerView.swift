import AppKit
import EdithKit
import SwiftUI

struct NotchAudioTab: View {
    var body: some View {
        if #available(macOS 14.4, *) {
            AudioMixerView()
        } else {
            Text("Per-app volume needs macOS 14.4 or later")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@available(macOS 14.4, *)
private struct AudioMixerView: View {
    @State private var engine = MixerEngine.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let error = engine.errorMessage {
                    errorView(error)
                }
                if engine.apps.isEmpty {
                    Text("Play audio in an app to control it here")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(engine.apps) { app in
                        row(app)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .onAppear { engine.viewAppeared() }
        .onDisappear { engine.viewDisappeared() }
    }

    private func row(_ app: MixerApp) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text(app.name).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1)
                    .frame(width: 80, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(app.volume) },
                        set: { engine.setVolume(app, Float($0)) }), in: 0...1
                )
                .controlSize(.mini)
                Text("\(Int(app.volume * 100))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                Menu {
                    Button {
                        engine.setOutput(app, nil)
                    } label: {
                        if app.outputUID == nil { Label("System output", systemImage: "checkmark") }
                        else { Text("System output") }
                    }
                    Divider()
                    ForEach(engine.outputDevices) { device in
                        Button {
                            engine.setOutput(app, device.uid)
                        } label: {
                            if app.outputUID == device.uid {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    Text(outputName(app))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.leading, 32)
        }
    }

    private func outputName(_ app: MixerApp) -> String {
        guard let uid = app.outputUID else { return "System output" }
        return engine.outputDevices.first(where: { $0.uid == uid })?.name
            ?? "Unavailable output"
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.orange)
            HStack(spacing: 10) {
                Button("Retry") { engine.retry() }
                Button("Open Settings") {
                    _ = try? PermissionOperationCenter.application.openSettings(
                        for: .applicationAudio)
                }
            }
            .buttonStyle(.edith(.borderless))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
