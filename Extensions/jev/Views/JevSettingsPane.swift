import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct JevSettingsPane: View {
    @Bindable var model: JevSettingsModel
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        PageScaffold {
            PageHeader("Jev")
        } content: {
            PageLoading(
                state: model.loading.state, message: "Jev could not load its settings.",
                layout: .list, refreshing: model.loading.isRefreshing,
                retry: { model.load(probe: false) }
            ) {
                PageCard(title: "TypeSafe API key") { keySection }
                PageCard(title: "What Jev powers") { featuresSection }
                PageCard(title: "Activity") { activitySection }
            }
        }
        .pageTask(cancel: { model.cancel() }) {
            if automaticActionsEnabled { model.load(probe: false) }
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
                .onSubmit { model.save() }
                .accessibilityLabel("TypeSafe API key")
                Button(model.loading.isRunning ? "Saving..." : "Save") {
                    model.save()
                }
                .disabled(
                    model.draft.trimmingCharacters(in: .whitespaces).isEmpty
                        || model.loading.isRunning)
            }
            HStack(spacing: UIScale.pt(10)) {
                Button(model.loading.isRunning ? "Checking..." : "Check key") {
                    model.load(probe: true)
                }
                .disabled(model.status?.isConfigured != true || model.loading.isRunning)
                Button("Remove key", role: .destructive) {
                    model.remove()
                }
                .disabled(model.status?.hasSavedKey != true || model.loading.isRunning)
            }
            if let message = model.loading.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("TypeSafe API key")
        } footer: {
            Text(
                "Jev answers typed questions in about a tenth of a second. Edith only calls it while a key is saved here, and every feature falls back to its own rules without one. The key stays in the Jev extension's Keychain item. Get one at console.typesafe.ai."
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
