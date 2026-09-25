import EdithKit
import SwiftUI

@MainActor
final class JevSettingsModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case saving
        case failed(String)
    }

    @Published var status: JevStatus?
    @Published var phase: Phase = .idle
    @Published var draft = ""

    private let decider: AgentJevDecider

    init(decider: AgentJevDecider = AgentJevDecider()) {
        self.decider = decider
    }

    var isBusy: Bool { phase == .loading || phase == .saving }

    func load(probe: Bool) async {
        phase = .loading
        do {
            status = try await decider.status(probe: probe)
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func save() async {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        phase = .saving
        do {
            status = try await decider.setKey(key)
            draft = ""
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func remove() async {
        phase = .saving
        do {
            status = try await decider.setKey(nil)
            phase = .idle
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? AgentError { return error.message }
        return error.localizedDescription
    }
}

struct JevSettingsPane: View {
    @StateObject private var model = JevSettingsModel()
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        Form {
            keySection
            featuresSection
            activitySection
        }
        .formStyle(.grouped)
        .navigationTitle("Jev")
        .task {
            if automaticActionsEnabled { await model.load(probe: false) }
        }
    }

    private var keySection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: UIScale.pt(6)) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                        .accessibilityHidden(true)
                    Text(model.status?.summary ?? "Checking...")
                        .foregroundStyle(.secondary)
                }
            }
            if let hint = model.status?.keyHint {
                LabeledContent("Key", value: hint)
            }
            if let message = model.status?.message {
                Text(message)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: UIScale.pt(8)) {
                SecureField(
                    model.status?.hasSavedKey == true ? "Replace the key" : "TypeSafe API key",
                    text: $model.draft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.save() } }
                .accessibilityLabel("TypeSafe API key")
                Button(model.phase == .saving ? "Saving..." : "Save") {
                    Task { await model.save() }
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
            }
            HStack(spacing: UIScale.pt(10)) {
                Button(model.phase == .loading ? "Checking..." : "Check key") {
                    Task { await model.load(probe: true) }
                }
                .disabled(model.status?.isConfigured != true || model.isBusy)
                Button("Remove key", role: .destructive) {
                    Task { await model.remove() }
                }
                .disabled(model.status?.hasSavedKey != true || model.isBusy)
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("TypeSafe API key")
        } footer: {
            Text(
                "Jev answers typed questions in about a tenth of a second. Edith only calls it while a key is saved here, and every feature falls back to its own rules without one. The key stays in the background agent's Keychain item. Get one at console.typesafe.ai."
            )
        }
    }

    private var featuresSection: some View {
        Section {
            ForEach(JevFeature.catalog) { feature in
                LabeledContent {
                    Text(model.status?.isConfigured == true ? "On" : "Off")
                        .foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text(feature.title)
                        Text(feature.detail)
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("What Jev powers")
        }
    }

    private var activitySection: some View {
        Section {
            LabeledContent("Decisions since launch", value: "\(model.status?.decisions ?? 0)")
            LabeledContent(
                "Median latency",
                value: model.status?.medianMilliseconds.map { "\($0) ms" } ?? "-")
            if let models = model.status?.models, !models.isEmpty {
                LabeledContent("Models", value: models.joined(separator: ", "))
            }
        } header: {
            Text("Activity")
        }
    }

    private var stateColor: Color {
        switch model.status?.state {
        case .ready: .green
        case .noCredits, .paused, .unreachable: .orange
        case .keyRejected, .keyUnreadable: .red
        case .notConfigured, .none: .secondary
        }
    }
}
