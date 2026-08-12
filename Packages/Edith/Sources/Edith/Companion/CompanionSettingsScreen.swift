import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CompanionSettingsModel: ObservableObject {
    @Published var provider = "anthropic"
    @Published var model = ""
    @Published var url = ""
    @Published var apiKey = ""
    @Published private(set) var current: CompanionReasonSettings?
    @Published private(set) var saving = false
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?
    @Published private(set) var testPassed = false
    @Published private(set) var syncing = false
    @Published private(set) var syncResult: String?
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var connectors: CompanionConnectorSettings?
    @Published var githubToken = ""
    @Published var notionToken = ""
    @Published private(set) var savingTokens = false
    @Published private(set) var syncingNotion = false
    @Published private(set) var importing = false

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func load() async {
        do {
            let settings = try await client.reasonSettings()
            apply(settings)
            connectors = try? await client.connectorSettings()
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveTokens() async {
        guard !savingTokens else { return }
        let github = githubToken.trimmingCharacters(in: .whitespaces)
        let notion = notionToken.trimmingCharacters(in: .whitespaces)
        guard !github.isEmpty || !notion.isEmpty else {
            error = "Paste a token first; leaving both blank changes nothing."
            return
        }
        savingTokens = true
        defer { savingTokens = false }
        do {
            connectors = try await client.updateConnectorSettings(
                github: github.isEmpty ? nil : github,
                notion: notion.isEmpty ? nil : notion)
            githubToken = ""
            notionToken = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearToken(_ which: String) async {
        guard !savingTokens else { return }
        savingTokens = true
        defer { savingTokens = false }
        do {
            connectors = try await client.updateConnectorSettings(
                github: which == "github" ? "" : nil,
                notion: which == "notion" ? "" : nil)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func importExport(source: String, url: URL) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let data = try Data(contentsOf: url)
            let outcome = try await client.importConnector(source: source, json: data)
            syncResult =
                "\(source): read \(outcome.entriesRead), stored "
                + "\(outcome.observationsInserted)"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func syncNotion() async {
        guard !syncingNotion else { return }
        syncingNotion = true
        defer { syncingNotion = false }
        do {
            let outcome = try await client.syncNotion(full: false)
            syncResult =
                "\(outcome.pagesWritten) pages, \(outcome.episodesIngested) new episodes"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ settings: CompanionReasonSettings) {
        current = settings
        provider = settings.provider == "openai" ? "openai" : "anthropic"
        model = settings.model
        url = settings.url
    }

    func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
            let settings = try await client.updateReasonSettings(
                provider: provider,
                url: url.trimmingCharacters(in: .whitespaces),
                model: model.trimmingCharacters(in: .whitespaces),
                apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
            apply(settings)
            apiKey = ""
            testResult = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func test() async {
        guard !testing else { return }
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let outcome = try await client.testReason()
            testPassed = outcome.ok
            testResult = "ok · \(outcome.latencyMs) ms"
            error = nil
        } catch {
            testPassed = false
            testResult = error.localizedDescription
        }
    }

    func syncGithub() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let outcome = try await client.syncGithub()
            syncResult =
                "\(outcome.eventsFetched) events, \(outcome.observationsInserted) new observations"
            error = nil
        } catch {
            syncResult = error.localizedDescription
        }
    }
}

struct CompanionSettingsScreen: View {
    @ObservedObject var model: CompanionSettingsModel
    @ObservedObject var home: CompanionHomeModel
    @AppStorage("companionEndpoint", store: SharedDefaults.store)
    private var endpoint = "http://127.0.0.1:4820"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @FocusState private var keyFocused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if let error = model.error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    reasonerCard
                    VStack(spacing: UIScale.pt(12)) {
                        healthCard
                        connectionCard
                    }
                }
                connectorsCard
            }
            .pageContent(compact)
        }
        .task {
            if requestsEnabled { await model.load() }
        }
    }

    private var reasonerCard: some View {
        SkinCard(
            title: "Reasoner",
            note: model.current?.configured == true ? nil : "not configured",
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                fieldLabel("Provider")
                Picker("", selection: $model.provider) {
                    Text("Anthropic").tag("anthropic")
                    Text("Local (Ollama)").tag("openai")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: UIScale.pt(260))

                if model.provider == "openai" {
                    fieldLabel("Endpoint URL")
                    EdithTextField(placeholder: "http://ollama:11434/v1", text: $model.url)
                }

                fieldLabel("Model")
                EdithTextField(
                    placeholder: model.provider == "openai" ? "qwen3:1.7b" : "claude-sonnet-5",
                    text: $model.model)

                if model.provider == "anthropic" || !(model.current?.apiKeyHint.isEmpty ?? true) {
                    fieldLabel("API key")
                    SecureField(keyPlaceholder, text: $model.apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(DashSkin.ink(dark))
                        .focused($keyFocused)
                        .focusEffectDisabled()
                        .edithFieldSurface(focused: keyFocused)
                    Text(
                        "Stored on the companion and hot-swapped into the running service. "
                            + "Never written to this Mac's defaults or the iCloud settings backup."
                    )
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(.top, UIScale.pt(2))
                }

                HStack(spacing: UIScale.pt(8)) {
                    Button(model.saving ? "Saving…" : "Save") {
                        Task { await model.save() }
                    }
                    .disabled(model.saving)
                    Button(model.testing ? "Testing…" : "Test connection") {
                        Task { await model.test() }
                    }
                    .disabled(model.testing)
                    if let result = model.testResult {
                        HStack(spacing: UIScale.pt(4)) {
                            Image(
                                systemName: model.testPassed
                                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(model.testPassed ? .green : .orange)
                            Text(result)
                                .foregroundStyle(DashSkin.inkSoft(dark))
                                .lineLimit(2)
                        }
                        .font(.system(size: UIScale.pt(11)))
                    }
                }
                .padding(.top, UIScale.pt(10))

                if let current = model.current {
                    Text(current.description)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .padding(.top, UIScale.pt(6))
                }
            }
        }
    }

    private var keyPlaceholder: String {
        guard let current = model.current, current.hasApiKey else { return "sk-…" }
        return "•••••••• current: \(current.apiKeyHint)"
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.top, UIScale.pt(9))
    }

    private var healthCard: some View {
        SkinCard(title: "Health", note: home.healthy ? "healthy" : "degraded", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                if home.checks.isEmpty {
                    Text(home.error ?? "Waiting for the companion to answer…")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else {
                    ForEach(home.checks, id: \.name) { check in
                        HStack(spacing: UIScale.pt(8)) {
                            Circle()
                                .fill(check.ok ? Color.green : Color.orange)
                                .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                            Text("\(check.name) · \(check.detail)")
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(
                                    check.ok ? DashSkin.inkSoft(dark) : .orange
                                )
                                .lineLimit(1)
                                .help(check.detail)
                        }
                    }
                }
            }
        }
    }

    private var connectorsCard: some View {
        SkinCard(
            title: "Connectors",
            note: "traces of what you actually did",
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                tokenRow(
                    label: "GitHub token",
                    placeholder: "ghp_… or gho_…",
                    text: $model.githubToken,
                    state: model.connectors?.github,
                    which: "github")
                tokenRow(
                    label: "Notion token",
                    placeholder: "ntn_…",
                    text: $model.notionToken,
                    state: model.connectors?.notion,
                    which: "notion")
                HStack(spacing: UIScale.pt(8)) {
                    Button(model.savingTokens ? "Saving…" : "Save tokens") {
                        Task { await model.saveTokens() }
                    }
                    .disabled(model.savingTokens)
                    Button(model.syncing ? "Syncing GitHub…" : "Sync GitHub") {
                        Task { await model.syncGithub() }
                    }
                    .disabled(model.syncing || model.connectors?.github.configured != true)
                    Button(model.syncingNotion ? "Syncing Notion…" : "Sync Notion") {
                        Task { await model.syncNotion() }
                    }
                    .disabled(model.syncingNotion || model.connectors?.notion.configured != true)
                }
                Divider().opacity(0.3)
                fieldLabel("Import an export")
                HStack(spacing: UIScale.pt(8)) {
                    ForEach(["calendar", "music", "youtube"], id: \.self) { source in
                        Button(model.importing ? "Importing…" : source) {
                            pickExport(source)
                        }
                        .disabled(model.importing)
                    }
                }
                Text(
                    "Tokens are stored on the companion, never on this Mac, and take effect "
                        + "without a restart. Calendar, music and YouTube have no live API "
                        + "worth using, so they come from an export you re-import."
                )
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private func pickExport(_ source: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Pick the \(source) export to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importExport(source: source, url: url) }
    }

    private func tokenRow(
        label: String, placeholder: String, text: Binding<String>,
        state: CompanionConnectorState?, which: String
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack(spacing: UIScale.pt(8)) {
                fieldLabel(label)
                Spacer(minLength: 0)
                Text(state?.detail ?? "not loaded")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(
                        state?.configured == true
                            ? DashSkin.inkSoft(dark)
                            : DashSkin.inkFaint(dark)
                    )
                    .lineLimit(1)
                if state?.configured == true {
                    Button("Clear") {
                        Task { await model.clearToken(which) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.accent(dark))
                    .pointerCursor()
                    .disabled(model.savingTokens)
                }
            }
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .focusEffectDisabled()
                .edithFieldSurface(focused: false)
        }
    }

    private var connectionCard: some View {
        SkinCard(title: "Connection", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                fieldLabel("Companion endpoint")
                EdithTextField(placeholder: "http://127.0.0.1:4820", text: $endpoint)
                if let result = model.syncResult {
                    Text(result)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(2)
                        .padding(.top, UIScale.pt(8))
                }
            }
        }
    }
}
