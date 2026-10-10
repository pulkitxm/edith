import AppKit
import EdithExtensionSupport
import Foundation
import Observation

@available(macOS 14.4, *) @MainActor protocol AudioMixerPresenting {
    var apps: [MixerApp] { get }
    var errorMessage: String? { get }
    func setVolume(_ app: MixerApp, _ volume: Float)
    func retry()
    func viewAppeared()
    func viewDisappeared()
}

struct AudioMixerUISnapshot: Codable {
    let apps: [AudioMixerAppRecord]
    let icons: [String: Data]
    let error: String?
}

@available(macOS 14.4, *) @MainActor @Observable
final class AudioMixerRemoteModel: AudioMixerPresenting {
    private(set) var apps: [MixerApp] = []
    private(set) var errorMessage: String?
    private let client: ExtensionEngineClient
    private var poll: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private var revision = 0
    private var stopped = false
    private var attachments = 0

    init(client: ExtensionEngineClient) { self.client = client }
    func viewAppeared() {
        guard !stopped else { return }
        attachments += 1
        guard attachments == 1 else { return }
        poll = Task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func viewDisappeared() {
        attachments = max(0, attachments - 1)
        guard attachments == 0 else { return }
        poll?.cancel(); poll = nil
    }
    func retry() {
        guard !stopped else { return }
        action?.cancel()
        revision += 1
        action = Task { await refresh() }
    }
    func setVolume(_ app: MixerApp, _ volume: Float) {
        guard !stopped, volume.isFinite, (0...1).contains(volume),
            apps.contains(where: {
                $0.objectID == app.objectID && $0.pid == app.pid && $0.bundleID == app.bundleID
            })
        else { return }
        action?.cancel(); revision += 1
        let generation = revision
        let request = AudioMixerRuntimeRequest(
            request: .volume, volume: Double(volume), deadline: Date().addingTimeInterval(8),
            target: .init(objectID: app.objectID, pid: app.pid, bundleID: app.bundleID))
        action = Task {
            do {
                let payload = try JSONSerialization.data(withJSONObject: request.payload)
                let data = try await client.invoke("audioMixer.request", payload: payload)
                let result = try JSONDecoder().decode(AudioMixerListSnapshot.self, from: data)
                guard !stopped, !Task.isCancelled, generation == revision else { return }
                publish(result.apps, icons: [:]); errorMessage = nil
            } catch is CancellationError {} catch {
                guard !stopped, generation == revision else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
    private func refresh() async {
        let generation = revision
        do {
            let data = try await client.invoke("audioMixer.ui.snapshot")
            let snapshot = try JSONDecoder().decode(AudioMixerUISnapshot.self, from: data)
            guard !stopped, !Task.isCancelled, generation == revision else { return }
            publish(snapshot.apps, icons: snapshot.icons); errorMessage = snapshot.error
        } catch is CancellationError {} catch {
            guard !stopped, generation == revision else { return }
            errorMessage = error.localizedDescription
        }
    }
    private func publish(_ records: [AudioMixerAppRecord], icons: [String: Data]) {
        apps = records.map { record in
            MixerApp(
                objectID: record.objectID, pid: record.pid, bundleID: record.bundleID,
                name: record.name,
                icon: icons[String(record.objectID)].flatMap(NSImage.init(data:))
                    ?? apps.first(where: { $0.objectID == record.objectID && $0.pid == record.pid }
                    )?.icon,
                volume: Float(record.normalizedVolume))
        }
    }
    func stop() {
        stopped = true; revision += 1
        poll?.cancel(); poll = nil
        action?.cancel(); action = nil
        attachments = 0
    }
}
