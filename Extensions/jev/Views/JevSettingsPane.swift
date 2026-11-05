import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct JevSettingsPane: View {
    @Bindable var model: JevSettingsModel
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        Form {
            keySection
            featuresSection
            activitySection
        }
        .edithForm()
        .pageTask {
            if automaticActionsEnabled { model.load(probe: false) }
        }
    }

    @ViewBuilder private var introNotice: some View {
        if model.status?.hasSavedKey != true, model.status != nil {
            PageNotice(
                "Everything in Edith already works without Jev. Add a TypeSafe API key only if you want faster, smarter decisions in the features listed below.",
                title: "Jev is optional", symbol: "sparkles"
            )
            .padding(.bottom, UIScale.pt(16))
        }
    }

    private var draftIsEmpty: Bool { model.draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private var keySection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: UIScale.pt(6)) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: UIScale.pt(8), height: UIScale.pt(8))
                        .accessibilityHidden(true)
                    if let summary = model.status?.summary {
                        Text(summary).foregroundStyle(.secondary)
                    } else {
                        SkeletonBlock(width: 90, height: 12)
                    }
                }
            }
            if let hint = model.status?.keyHint {
                LabeledContent("Saved key") {
                    Text(hint).font(.edithText(.body).monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let message = model.status?.message {
                Text(message)
                    .font(.edithText(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                Text(model.status?.hasSavedKey == true ? "Replace key" : "API key")
                Spacer(minLength: UIScale.pt(12))
                SecureField(
                    "TypeSafe API key", text: $model.draft,
                    prompt: Text("Paste your TypeSafe API key")
                )
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: UIScale.pt(160), maxWidth: UIScale.pt(320))
                .onSubmit { model.save() }
                .accessibilityLabel("TypeSafe API key")
                Button(model.phase == .saving ? "Saving..." : "Save") {
                    model.save()
                }
                .buttonStyle(.edith(draftIsEmpty ? .secondary : .primary))
                .disabled(draftIsEmpty || model.isBusy)
                .help(draftIsEmpty ? "Paste a key first." : "Saves the key to your Keychain.")
            }
            if model.status?.hasSavedKey == true {
                LabeledContent {
                    HStack(spacing: UIScale.pt(8)) {
                        Button(model.phase == .loading ? "Checking..." : "Check key") {
                            model.load(probe: true)
                        }
                        .buttonStyle(.edith(.secondary))
                        .disabled(model.status?.isConfigured != true || model.isBusy)
                        Button("Remove key", role: .destructive) {
                            model.remove()
                        }
                        .buttonStyle(.edith(.secondary))
                        .disabled(model.isBusy)
                        .help(
                            "Deletes the saved key from your Keychain. Features go back to their built-in rules."
                        )
                    }
                } label: {
                    Text("Manage key")
                    Text(
                        "Check sends one tiny request to confirm the key works and has credits. Remove deletes it from this Mac only."
                    )
                    .font(.edithText(.subheadline))
                }
            }
            if case .failed(let message) = model.phase {
                PageNotice(message, tone: .warning) {
                    EmptyView()
                } actions: {
                    Button("Try again") { model.load(probe: model.status?.isConfigured == true) }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 0) {
                introNotice
                Text("TypeSafe API key")
            }
        } footer: {
            HStack(spacing: UIScale.pt(4)) {
                Text("Edith calls Jev only while a key is saved. The key stays in your Keychain.")
                Link("Get a key", destination: URL(string: "https://console.typesafe.ai")!)
            }
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
        }
    }

    private var featuresSection: some View {
        Section {
            ForEach(JevFeature.catalog) { feature in
                LabeledContent {
                    Text(model.status?.state == .ready ? "Using Jev" : "Built-in rules")
                        .foregroundStyle(.secondary)
                } label: {
                    Text(feature.title)
                    Text(feature.detail).font(.edithText(.subheadline))
                }
            }
        } header: {
            Text("What Jev powers")
        } footer: {
            Text(
                "Without a key, each feature uses its own built-in rules. With one, Jev answers in about a tenth of a second."
            )
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
        }
    }

    private var activitySection: some View {
        Section {
            LabeledContent("Decisions since launch") {
                Text("\(model.status?.decisions ?? 0)").monospacedDigit()
            }
            LabeledContent("Median response time") {
                Text(model.status?.medianMilliseconds.map { "\($0) ms" } ?? "None yet")
                    .monospacedDigit()
            }
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
