import AppKit
import EdithKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class CompanionSettingsModel {
    var provider = "anthropic"
    var model = ""
    var url = ""
    var apiKey = ""
    private(set) var current: CompanionReasonSettings?
    private(set) var saving = false
    private(set) var testing = false
    private(set) var testResult: String?
    private(set) var testPassed = false
    private(set) var syncingGithub = false
    private(set) var syncingNotion = false
    private(set) var connectorStatus: String?
    private(set) var connectorStatusIsError = false
    private(set) var reasonerStatus: String?
    private(set) var reasonerStatusIsError = false
    private(set) var error: String?
    private(set) var loaded = false
    private(set) var connectors: CompanionConnectorSettings?
    var githubToken = ""
    var notionToken = ""
    private(set) var savingTokens = false
    private(set) var importing = false
    private(set) var exporting = false
    private(set) var restoring = false
    private(set) var wiping = false
    private(set) var reindexing = false
    private(set) var rebuilding = false
    private(set) var dataStatus: String?
    private(set) var dataStatusIsError = false
    private(set) var dangerStatus: String?
    private(set) var dangerStatusIsError = false

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func load() async {
        do {
            let settings = try await client.reasonSettings()
            apply(settings, refreshDrafts: !loaded)
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
            connectorStatus = "Paste a token first; leaving both blank changes nothing."
            connectorStatusIsError = true
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
            connectorStatus = "Saved on the companion."
            connectorStatusIsError = false
        } catch {
            connectorStatus = error.localizedDescription
            connectorStatusIsError = true
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
            connectorStatus = "Cleared."
            connectorStatusIsError = false
        } catch {
            connectorStatus = error.localizedDescription
            connectorStatusIsError = true
        }
    }

    func importExport(source: String, url: URL) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let data = try Data(contentsOf: url)
            let outcome = try await client.importConnector(source: source, json: data)
            connectorStatus =
                "\(source): read \(outcome.entriesRead), stored \(outcome.observationsInserted)"
            connectorStatusIsError = false
        } catch {
            connectorStatus = error.localizedDescription
            connectorStatusIsError = true
        }
    }

    func syncNotion() async {
        guard !syncingNotion else { return }
        syncingNotion = true
        defer { syncingNotion = false }
        do {
            let outcome = try await client.syncNotion(full: false)
            connectorStatus =
                "Notion: \(outcome.pagesWritten) pages, \(outcome.episodesIngested) new episodes"
            connectorStatusIsError = false
        } catch {
            connectorStatus = error.localizedDescription
            connectorStatusIsError = true
        }
    }

    func syncGithub() async {
        guard !syncingGithub else { return }
        syncingGithub = true
        defer { syncingGithub = false }
        do {
            let outcome = try await client.syncGithub()
            connectorStatus =
                "GitHub: \(outcome.eventsFetched) events, "
                + "\(outcome.observationsInserted) new observations"
            connectorStatusIsError = false
        } catch {
            connectorStatus = error.localizedDescription
            connectorStatusIsError = true
        }
    }

    private func apply(_ settings: CompanionReasonSettings, refreshDrafts: Bool = true) {
        current = settings
        guard refreshDrafts else { return }
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
            reasonerStatus = "Saved and swapped into the running service."
            reasonerStatusIsError = false
        } catch {
            reasonerStatus = error.localizedDescription
            reasonerStatusIsError = true
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
            reasonerStatus = nil
        } catch {
            testPassed = false
            testResult = error.localizedDescription
        }
    }

    func exportData(into directory: URL) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let result = try await CompanionDataTransfer.export(
                client: client, into: directory, includeMedia: true)
            let episodes = result.counts["episodes"] ?? 0
            let conversations = result.counts["conversations"] ?? 0
            dataStatus =
                "Exported \(episodes) episodes and \(conversations) conversations "
                + "to \(result.directory)"
                + (result.mediaSaved > 0 ? ", media included" : "")
            dataStatusIsError = false
        } catch {
            dataStatus = error.localizedDescription
            dataStatusIsError = true
        }
    }

    func restoreData(from path: URL) async {
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            let result = try await CompanionDataTransfer.restore(client: client, from: path)
            var parts = [
                "Restored \(result.outcome.episodesInserted) episodes and "
                    + "\(result.outcome.conversationsInserted) conversations"
            ]
            if result.outcome.episodesSkipped > 0 {
                parts.append("\(result.outcome.episodesSkipped) already there")
            }
            if result.mediaRestored > 0 {
                parts.append("\(result.mediaRestored) media files")
            }
            dataStatus = parts.joined(separator: "; ")
            dataStatusIsError = false
        } catch {
            dataStatus = error.localizedDescription
            dataStatusIsError = true
        }
    }

    func reindex() async {
        guard !reindexing else { return }
        reindexing = true
        defer { reindexing = false }
        do {
            let outcome = try await client.db("reindex")
            dangerStatus = "Dropped \(outcome.chunksDropped ?? 0) chunks; re-embedding now."
            dangerStatusIsError = false
            _ = try? await client.index()
        } catch {
            dangerStatus = error.localizedDescription
            dangerStatusIsError = true
        }
    }

    func rebuildDerived() async {
        guard !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        do {
            let outcome = try await client.db("rebuild-derived")
            dangerStatus =
                "Dropped \(outcome.chunksDropped ?? 0) chunks, retired "
                + "\(outcome.beliefsRetired ?? 0) beliefs, kept "
                + "\(outcome.episodesKept ?? 0) episodes."
            dangerStatusIsError = false
        } catch {
            dangerStatus = error.localizedDescription
            dangerStatusIsError = true
        }
    }

    func wipeEverything() async {
        guard !wiping else { return }
        wiping = true
        defer { wiping = false }
        do {
            let outcome = try await client.wipe(confirm: "everything")
            dangerStatus =
                "Wiped \(outcome.episodesDropped) episodes, "
                + "\(outcome.observationsDropped) observations, "
                + "\(outcome.conversationsDropped) conversations."
            dangerStatusIsError = false
        } catch {
            dangerStatus = error.localizedDescription
            dangerStatusIsError = true
        }
    }
}

struct CompanionSettingsScreen: View {
    @Bindable var model: CompanionSettingsModel
    let home: CompanionHomeModel
    @AppStorage(AppStorageKeys.Companion.endpoint, store: SharedDefaults.store)
    private var endpoint = CompanionClient.defaultEndpointString
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @State private var endpointDraft = ""
    @State private var endpointLoaded = false
    @State private var confirmingWipe = false
    @FocusState private var endpointFocused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Group {
                    if !model.loaded {
                        if let error = model.error {
                            unreachableCard(error)
                                .frame(
                                    maxWidth: CompanionMetrics.columnWidth,
                                    alignment: .leading)
                        } else {
                            CompanionGrid(width: proxy.size.width) {
                                CompanionCardSkeleton(rows: 3, dark: dark)
                            } secondary: {
                                CompanionCardSkeleton(rows: 2, dark: dark)
                            } full: {
                            }
                        }
                    } else {
                        CompanionGrid(width: proxy.size.width) {
                            reasonerCard
                            connectorsCard
                            dataCard
                        } secondary: {
                            healthCard
                            connectionCard
                            dangerCard
                        } full: {
                        }
                    }
                }
                .pageContent(compact)
            }
        }
        .task(id: generation) {
            if requestsEnabled { await model.load() }
        }
        .onAppear {
            guard !endpointLoaded else { return }
            endpointDraft = endpoint
            endpointLoaded = true
        }
        .sheet(isPresented: $confirmingWipe) {
            CompanionConfirmSheet(
                title: "Wipe the companion?",
                message:
                    "Every episode, observation, belief and conversation is deleted, along "
                    + "with the files behind them. The stack keeps running and its settings "
                    + "survive, but the memory is gone. Export first if any of it matters.",
                phrase: "WIPE",
                actionTitle: "Wipe everything"
            ) {
                Task { await model.wipeEverything() }
            }
        }
    }

    @ViewBuilder
    private func unreachableCard(_ error: String) -> some View {
        SkinCard(title: "Settings", note: "companion unreachable", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                Text(error)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
                CompanionButton(title: "Try again", role: .primary) {
                    Task { await model.load() }
                }
            }
        }
        connectionCard
    }

    private var reasonerCard: some View {
        SkinCard(
            title: "Reasoner",
            note: model.current?.configured == true ? nil : "not configured",
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: CompanionMetrics.rowSpacing) {
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    CompanionFieldLabel(text: "Provider")
                    Picker("", selection: $model.provider) {
                        Text("Anthropic").tag("anthropic")
                        Text("Local (Ollama)").tag("openai")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: UIScale.pt(280))
                }

                if model.provider == "openai" {
                    CompanionLabeledField(
                        label: "Endpoint URL", placeholder: "http://ollama:11434/v1",
                        text: $model.url,
                        onSubmit: { Task { await model.save() } })
                }

                CompanionLabeledField(
                    label: "Model",
                    placeholder: model.provider == "openai" ? "qwen3:1.7b" : "claude-sonnet-5",
                    text: $model.model,
                    onSubmit: { Task { await model.save() } })

                if model.provider == "anthropic" || !(model.current?.apiKeyHint.isEmpty ?? true) {
                    CompanionSecureField(
                        label: "API key", placeholder: keyPlaceholder, text: $model.apiKey,
                        onSubmit: { Task { await model.save() } })
                    Text(
                        "Stored on the companion and hot-swapped into the running service. "
                            + "Never written to this Mac's defaults or the iCloud settings backup."
                    )
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }

                HStack(spacing: UIScale.pt(8)) {
                    CompanionButton(
                        title: "Save", role: .primary, busy: model.saving, busyTitle: "Saving…"
                    ) {
                        Task { await model.save() }
                    }
                    CompanionButton(
                        title: "Test connection", busy: model.testing, busyTitle: "Testing…"
                    ) {
                        Task { await model.test() }
                    }
                    if let result = model.testResult {
                        CompanionStatusLine(text: result, tone: model.testPassed ? .ok : .error)
                    }
                }
                .padding(.top, UIScale.pt(4))

                if let status = model.reasonerStatus {
                    CompanionStatusLine(
                        text: status, tone: model.reasonerStatusIsError ? .error : .ok)
                } else if let current = model.current {
                    Text(current.description)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
    }

    private var keyPlaceholder: String {
        guard let current = model.current, current.hasApiKey else { return "sk-…" }
        return "•••••••• current: \(current.apiKeyHint)"
    }

    private var healthCard: some View {
        SkinCard(title: "Health", note: home.healthy ? "healthy" : "degraded", dark: dark) {
            if home.checks.isEmpty {
                Text(home.error ?? "Waiting for the companion to answer…")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: UIScale.pt(290)), spacing: UIScale.pt(14),
                            alignment: .leading)
                    ],
                    alignment: .leading, spacing: UIScale.pt(7)
                ) {
                    ForEach(home.checks, id: \.name) { check in
                        HStack(spacing: UIScale.pt(8)) {
                            Circle()
                                .fill(check.ok ? DashSkin.ok : DashSkin.warn)
                                .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                            Text("\(check.name) · \(check.detail)")
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(
                                    check.ok ? DashSkin.inkSoft(dark) : DashSkin.warn
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
            VStack(alignment: .leading, spacing: CompanionMetrics.rowSpacing) {
                CompanionSecureField(
                    label: "GitHub token", placeholder: "ghp_… or gho_…",
                    text: $model.githubToken,
                    detail: model.connectors?.github.detail ?? "not loaded",
                    detailEmphasis: model.connectors?.github.configured == true,
                    clear: model.connectors?.github.configured == true
                        ? { Task { await model.clearToken("github") } } : nil,
                    clearDisabled: model.savingTokens,
                    onSubmit: { Task { await model.saveTokens() } })
                CompanionSecureField(
                    label: "Notion token", placeholder: "ntn_…",
                    text: $model.notionToken,
                    detail: model.connectors?.notion.detail ?? "not loaded",
                    detailEmphasis: model.connectors?.notion.configured == true,
                    clear: model.connectors?.notion.configured == true
                        ? { Task { await model.clearToken("notion") } } : nil,
                    clearDisabled: model.savingTokens,
                    onSubmit: { Task { await model.saveTokens() } })

                HStack(spacing: UIScale.pt(8)) {
                    CompanionButton(
                        title: "Save tokens", role: .primary, busy: model.savingTokens,
                        busyTitle: "Saving…"
                    ) {
                        Task { await model.saveTokens() }
                    }
                    CompanionButton(
                        title: "Sync GitHub", busy: model.syncingGithub, busyTitle: "Syncing…",
                        disabled: model.connectors?.github.configured != true
                    ) {
                        Task { await model.syncGithub() }
                    }
                    CompanionButton(
                        title: "Sync Notion", busy: model.syncingNotion, busyTitle: "Syncing…",
                        disabled: model.connectors?.notion.configured != true
                    ) {
                        Task { await model.syncNotion() }
                    }
                }
                .padding(.top, UIScale.pt(4))

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    CompanionFieldLabel(text: "Import an export")
                    HStack(spacing: UIScale.pt(8)) {
                        CompanionButton(
                            title: "Calendar…", busy: model.importing, disabled: model.importing
                        ) {
                            pickExport("calendar")
                        }
                        CompanionButton(
                            title: "Music…", busy: model.importing, disabled: model.importing
                        ) {
                            pickExport("music")
                        }
                        CompanionButton(
                            title: "YouTube…", busy: model.importing, disabled: model.importing
                        ) {
                            pickExport("youtube")
                        }
                    }
                    Text(
                        "Tokens are stored on the companion, never on this Mac, and take "
                            + "effect without a restart. Calendar, music and YouTube have no "
                            + "live API worth using, so they come from an export you re-import."
                    )
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }

                if let status = model.connectorStatus {
                    CompanionStatusLine(
                        text: status, tone: model.connectorStatusIsError ? .error : .ok)
                }
            }
        }
    }

    private var connectionCard: some View {
        SkinCard(title: "Connection", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                CompanionFieldLabel(text: "Companion endpoint")
                EdithTextField(
                    placeholder: CompanionClient.defaultEndpointString, text: $endpointDraft,
                    invalid: !endpointDraftIsValid,
                    focus: $endpointFocused,
                    onSubmit: commitEndpoint)
                if !endpointDraftIsValid {
                    Label(
                        "Not a usable URL; the app keeps talking to \(endpoint)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.danger)
                } else {
                    Text(
                        endpointDraft == endpoint
                            ? "Where this Mac reaches the companion. A change applies when "
                                + "you press Return or leave the field."
                            : "Applies to \(endpointDraft) on Return, or when you leave the field."
                    )
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .onChange(of: endpointFocused) { _, focused in
                if !focused, endpointDraftIsValid { commitEndpoint() }
            }
        }
    }

    private var endpointDraftIsValid: Bool {
        let trimmed = endpointDraft.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme, url.host() != nil
        else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func commitEndpoint() {
        guard endpointDraftIsValid else { return }
        let trimmed = endpointDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != endpoint else { return }
        endpoint = trimmed
        endpointDraft = trimmed
    }

    private var dataCard: some View {
        SkinCard(title: "Your data", note: "it leaves whenever you say", dark: dark) {
            VStack(alignment: .leading, spacing: CompanionMetrics.rowSpacing) {
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("Export everything")
                            .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(
                            "Episodes, conversations, beliefs, observations and media, "
                                + "written to a folder as a restorable bundle. Tokens stay behind."
                        )
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: UIScale.pt(12))
                    CompanionButton(
                        title: "Export…", busy: model.exporting, busyTitle: "Exporting…"
                    ) {
                        pickExportDirectory()
                    }
                }
                Divider().opacity(0.3)
                HStack(alignment: .center, spacing: UIScale.pt(12)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        Text("Import a bundle")
                            .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        Text(
                            "Merges an exported bundle back in. Nothing is overwritten and "
                                + "what already exists is skipped, so importing twice is safe."
                        )
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: UIScale.pt(12))
                    CompanionButton(
                        title: "Import…", busy: model.restoring, busyTitle: "Importing…"
                    ) {
                        pickImportBundle()
                    }
                }
                if let status = model.dataStatus {
                    CompanionStatusLine(text: status, tone: model.dataStatusIsError ? .error : .ok)
                }
            }
        }
    }

    private var dangerCard: some View {
        SkinCard(title: "Danger zone", note: "none of this can be undone", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                CompanionDangerRow(
                    title: "Re-embed everything",
                    consequence:
                        "Drops the search index and embeds every episode again. Slow, "
                        + "harmless, and the fix after changing the embedding model.",
                    buttonTitle: "Reindex", busy: model.reindexing
                ) {
                    Task { await model.reindex() }
                }
                Divider().opacity(0.3)
                CompanionDangerRow(
                    title: "Rebuild what it thinks",
                    consequence:
                        "Retires every belief and fact and drops the index. Episodes and "
                        + "conversations survive; the nightly runs rebuild the rest.",
                    buttonTitle: "Rebuild", busy: model.rebuilding
                ) {
                    Task { await model.rebuildDerived() }
                }
                Divider().opacity(0.3)
                CompanionDangerRow(
                    title: "Wipe the memory",
                    consequence:
                        "Deletes every episode, observation, belief and conversation, and "
                        + "the files behind them. The stack and its settings survive.",
                    buttonTitle: "Wipe…", busy: model.wiping
                ) {
                    confirmingWipe = true
                }
                if let status = model.dangerStatus {
                    CompanionStatusLine(
                        text: status, tone: model.dangerStatusIsError ? .error : .ok
                    )
                    .padding(.top, UIScale.pt(6))
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(16))
                .strokeBorder(DashSkin.danger.opacity(0.35), lineWidth: UIScale.pt(1))
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

    private func pickExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose the folder the companion bundle is written into"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportData(into: url) }
    }

    private func pickImportBundle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Pick an exported folder, or its bundle.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.restoreData(from: url) }
    }
}
