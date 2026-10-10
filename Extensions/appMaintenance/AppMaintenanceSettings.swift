import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor @Observable final class MaintenanceSettingsModel {
    private(set) var preferences = MaintenanceUISettings()
    private(set) var packageKind = "formula"
    private(set) var loaded = false
    private(set) var packageLoaded = false
    private(set) var stopped = false
    var errorMessage: String?
    var packageError: String?
    private let send: @MainActor (String, Data) async throws -> Data
    private let invalidate: @MainActor () -> Void
    private var revision = 0
    private var tail: Task<Void, Never>?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    convenience init(engine: ExtensionEngineClient) {
        self.init(
            send: { try await engine.invoke($0, payload: $1) }, invalidate: { engine.invalidate() })
    }

    init(
        send: @escaping @MainActor (String, Data) async throws -> Data,
        invalidate: @escaping @MainActor () -> Void = {}
    ) {
        self.send = send
        self.invalidate = invalidate
    }

    func load() async {
        guard !stopped else { return }
        let current = revision
        do {
            let data = try await send("maintenance.ui.settings.read", Data("{}".utf8))
            try Task.checkCancellation()
            guard !stopped, revision == current else { return }
            preferences = try JSONDecoder().decode(MaintenanceUISettings.self, from: data)
            loaded = true
            errorMessage = nil
        } catch is CancellationError {} catch {
            if !stopped, revision == current { errorMessage = error.localizedDescription }
        }
        guard !stopped, revision == current else { return }
        do {
            let data = try await send("maintenance.ui.packageKind.read", Data("{}".utf8))
            try Task.checkCancellation()
            guard !stopped, revision == current else { return }
            packageKind = try JSONDecoder().decode(String.self, from: data)
            guard ["formula", "cask"].contains(packageKind) else {
                throw ExtensionPeerError.invalidRequest
            }
            packageLoaded = true
            packageError = nil
        } catch is CancellationError {} catch {
            if !stopped, revision == current { packageError = error.localizedDescription }
        }
    }

    func setDestination(_ destination: String) {
        guard loaded, !stopped, AppMaintenanceInstallDestination(rawValue: destination) != nil
        else { return }
        preferences.installDestination = destination
        do {
            enqueue("maintenance.ui.settings.write", payload: try JSONEncoder().encode(preferences))
            { [weak self] data in
                self?.preferences = try JSONDecoder().decode(MaintenanceUISettings.self, from: data)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func setPackageKind(_ kind: String) {
        guard packageLoaded, !stopped, ["formula", "cask"].contains(kind) else { return }
        packageKind = kind
        do {
            enqueue(
                "maintenance.ui.packageKind.write",
                payload: try JSONEncoder().encode(["kind": kind])
            ) { [weak self] data in
                self?.packageKind = try JSONDecoder().decode(String.self, from: data)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func enqueue(
        _ operation: String, payload: Data,
        apply: @escaping @MainActor (Data) throws -> Void
    ) {
        guard tasks.count < 8 else {
            errorMessage = "Wait for the current settings to save."; return
        }
        revision += 1
        let current = revision
        let previous = tail
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            await previous?.value
            guard let self, !stopped, !Task.isCancelled else { return }
            do {
                let data = try await send(operation, payload)
                try Task.checkCancellation()
                guard !stopped, revision == current else { return }
                try apply(data)
                errorMessage = nil
            } catch is CancellationError {} catch {
                if !stopped, revision == current { errorMessage = error.localizedDescription }
            }
        }
        tasks[id] = task
        tail = task
    }

    func finish() async { await tail?.value }

    func stop() {
        guard !stopped else { return }
        stopped = true
        revision += 1
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        tail = nil
        invalidate()
    }
}

struct AppMaintenanceSettings: View {
    @Bindable var model: MaintenanceSettingsModel

    var body: some View {
        Form {
            Section("Maintenance") {
                Picker(
                    "Default package kind",
                    selection: Binding(get: { model.packageKind }, set: model.setPackageKind)
                ) {
                    Text("Formulae").tag("formula")
                    Text("Casks").tag("cask")
                }
                .disabled(!model.packageLoaded || model.stopped)
                if let error = model.packageError {
                    Text(error).settingsCaption().foregroundStyle(.red)
                }
                LabeledContent("Removal", value: "Review first, then move to Trash")
                Text(
                    "Manage Homebrew packages, verify single-app disk images, and select exact support files before removal."
                )
                .settingsCaption()
                Picker(
                    "Disk image destination",
                    selection: Binding(
                        get: { model.preferences.installDestination }, set: model.setDestination)
                ) {
                    ForEach(AppMaintenanceInstallDestination.allCases, id: \.rawValue) {
                        destination in
                        Text(destination.title).tag(destination.rawValue)
                    }
                }
                .disabled(!model.loaded || model.stopped)
                LabeledContent("Location", value: "Main sidebar")
                if let error = model.errorMessage {
                    Text(error).settingsCaption().foregroundStyle(.red)
                }
                if model.errorMessage != nil || model.packageError != nil {
                    Button("Retry") { Task { await model.load() } }
                        .disabled(model.stopped)
                }
            }
            .opacity(model.stopped ? 0.5 : 1)
        }
        .formStyle(.grouped)
        .pageTask { await model.load() }
    }
}
