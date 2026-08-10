import AppKit
import SwiftUI

@available(macOS 14.4, *)
@MainActor
@Observable
final class MixerEngine {
    private(set) var apps: [MixerApp] = []

    private var taps: [pid_t: AppVolumeTap] = [:]
    private var savedGain: [String: Float] = [:]

    func refresh() {
        let processes = AudioProcessRegistry.audioProcesses()
        apps = processes.compactMap { process in
            guard let app = NSRunningApplication(processIdentifier: process.pid) else { return nil }
            return MixerApp(
                objectID: process.objectID, pid: process.pid, bundleID: process.bundleID,
                name: app.localizedName ?? process.bundleID, icon: app.icon,
                volume: savedGain[process.bundleID] ?? 1)
        }
    }

    func setVolume(_ app: MixerApp, _ value: Float) {
        savedGain[app.bundleID] = value
        if value >= 0.99 {
            taps[app.pid]?.destroy()
            taps[app.pid] = nil
        } else if let tap = taps[app.pid] {
            tap.setGain(value)
        } else if let tap = AppVolumeTap(processObjectID: app.objectID) {
            tap.setGain(value)
            taps[app.pid] = tap
        }
        refresh()
    }

    func shutdown() {
        for tap in taps.values { tap.destroy() }
        taps.removeAll()
    }
}

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
    private var engine = MixerEngine()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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
        .onAppear { engine.refresh() }
    }

    private func row(_ app: MixerApp) -> some View {
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
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 28, alignment: .trailing)
        }
    }
}
