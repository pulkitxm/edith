@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Observation
import SwiftUI

@MainActor @Observable final class AttentionTrackingSettingsModel {
    var settings = AttentionSettings()
    var message: String?
    var errorMessage: String?
    private(set) var loaded = false
    private(set) var stopped = false
    private let client: AttentionUIClient
    private var revision = 0

    init(client: AttentionUIClient) { self.client = client }

    func load() async {
        guard !stopped else { return }
        let current = revision
        do {
            let data = try await client.invoke("attention.settings.get")
            guard !stopped, current == revision else { return }
            settings = try AttentionPayload.decode(AttentionSettings.self, from: data)
            loaded = true
            errorMessage = nil
        } catch is CancellationError {} catch {
            guard !stopped, current == revision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func save() {
        guard loaded, !stopped else { return }
        settings.isEnabled = settings.trackingEnabled || settings.browserTrackingEnabled
        revision += 1
        let current = revision
        do {
            let payload = try AttentionPayload.encode(settings)
            client.perform("attention.settings.set", payload: payload) { [weak self] result in
                guard let self, !stopped, revision == current else { return }
                do {
                    settings = try AttentionPayload.decode(
                        AttentionSettings.self, from: result.get())
                    message = "Settings saved"
                    errorMessage = nil
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func stop() {
        stopped = true
        revision += 1
        client.stop()
    }
}

struct AttentionTrackingSettings: View {
    @Bindable var model: AttentionTrackingSettingsModel

    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Track foreground applications", isOn: $model.settings.trackingEnabled)
                Toggle("Run local browser server", isOn: $model.settings.browserTrackingEnabled)
                HStack {
                    Button("Save tracking settings") { model.save() }
                    Button("Open Attention") { ExtensionPresentation.showWindow() }
                }
                if let message = model.message {
                    Text(message).settingsCaption().foregroundStyle(.green)
                }
                if let error = model.errorMessage {
                    Text(error).settingsCaption().foregroundStyle(.red)
                }
            }
            .disabled(!model.loaded || model.stopped)
            .opacity(model.loaded && !model.stopped ? 1 : 0.5)
            if !model.loaded, let error = model.errorMessage {
                Section {
                    Text(error).settingsCaption().foregroundStyle(.red)
                    Button("Retry") { Task { await model.load() } }
                }
            }
        }
        .formStyle(.grouped)
        .pageTask { await model.load() }
    }
}
