import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct JevSettingsPane: View {
    @Bindable var model: JevSettingsModel
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        Form {
            introSection
            keySection
            featuresSection
            activitySection
        }
        .edithForm()
        .pageTask {
            if automaticActionsEnabled { model.load(probe: false) }
        }
    }

    private var introSection: some View {
        Section {
            if model.status?.hasSavedKey != true, model.status != nil {
                PageNotice(
                    "Everything in Edith already works without Jev. Add a TypeSafe API key below only if you want faster, smarter decisions in the features listed here.",
                    title: "Jev is optional", symbol: "sparkles")
            }
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
                    if let summary = model.status?.summary {
                        Text(summary).foregroundStyle(.secondary)
                    } else {
                        SkeletonBlock(width: 90, height: 11)
                    }
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
                    model.status?.hasSavedKey == true
                        ? "Paste a new key to replace it" : "Paste your TypeSafe API key",
                    text: $model.draft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.save() }
                .accessibilityLabel("TypeSafe API key")
                Button(model.phase == .saving ? "Saving..." : "Save") {
                    model.save()
                }
                .disabled(
                    model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy
                )
                .help(
                    model.draft.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Paste a key first." : "Saves the key to your Keychain.")
            }
            HStack(spacing: UIScale.pt(10)) {
                Button(model.phase == .loading ? "Checking..." : "Check key") {
                    model.load(probe: true)
                }
                .disabled(model.status?.isConfigured != true || model.isBusy)
                Button("Remove key", role: .destructive) {
                    model.remove()
                }
                .disabled(model.status?.hasSavedKey != true || model.isBusy)
                .help(
                    model.status?.hasSavedKey == true
                        ? "Deletes the saved key from your Keychain. Features go back to their built-in rules."
                        : "No key is saved.")
            }
            if model.status?.hasSavedKey == true {
                Text(
                    "Check key sends one tiny test request to confirm the key works and has credits. Remove key deletes it from this Mac's Keychain only."
                )
                .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
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
                "Jev answers typed questions in about a tenth of a second. Edith only calls it while a key is saved here, and every feature falls back to its own rules without one. The key stays in the Jev extension's Keychain item. Get one at console.typesafe.ai."
            )
        }
    }

    private var featuresSection: some View {
        Section {
            ForEach(JevFeature.catalog) { feature in
                LabeledContent {
                    Text(model.status?.isConfigured == true ? "Using Jev" : "Built-in rules")
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
