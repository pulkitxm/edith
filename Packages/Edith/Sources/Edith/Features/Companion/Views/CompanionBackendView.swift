import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct CompanionBackendScreen: View {
    @Bindable var model: CompanionBackendModel
    var openSetup: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmingDestroy = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                CompanionGrid(width: proxy.size.width) {
                    whereItRunsCard
                    configurationCard
                } secondary: {
                    if model.deployment != nil { servicesCard }
                    secretsCard
                    if model.deployment != nil { teardownCard }
                } full: {
                    if !model.lastLog.isEmpty { logCard }
                }
                .pageContent(compact)
            }
        }
        .task(id: generation) { if requestsEnabled { await model.refresh() } }
        .fileExporter(
            isPresented: $exporting,
            document: CompanionConfigDocument(data: model.exportBundle() ?? Data()),
            contentType: .json,
            defaultFilename: "companion-configuration"
        ) { _ in }
        .sheet(isPresented: $confirmingDestroy) {
            CompanionConfirmSheet(
                title: "Destroy the companion stack?",
                message:
                    "The containers stop and every volume is deleted: the database, the vault "
                    + "with your original files, and the downloaded models. This cannot be "
                    + "undone from here.",
                phrase: "DESTROY",
                actionTitle: "Destroy it all"
            ) {
                Task { await model.destroy() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            model.importBundle(data)
        }
    }

    private var whereItRunsCard: some View {
        SkinCard(title: "Where it runs", note: headline, dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                if model.hosts.isEmpty {
                    if model.probing {
                        ListRowsSkeleton(rows: 2, showsLeadingDot: true, dark: dark)
                    } else {
                        Text("No machines found yet.")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                } else {
                    ForEach(model.hosts) { host in
                        hostRow(host)
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    CompanionButton(
                        title: model.deployment == nil ? "Set it up here" : "Move it here",
                        role: .primary,
                        busy: model.busy != nil, busyTitle: model.busy.map { "\($0)…" },
                        disabled: !model.canDeploy
                    ) {
                        Task { await model.deploy() }
                    }
                    CompanionButton(
                        title: "Re-check", busy: model.probing, busyTitle: "Probing…"
                    ) {
                        Task { await model.probeHosts() }
                    }
                    CompanionLinkButton(
                        title: "Guided setup…",
                        help: "Walk through picking a machine and setting it up, step by step"
                    ) {
                        openSetup()
                    }
                    Spacer(minLength: 0)
                }
                if let error = model.error {
                    CompanionStatusLine(text: error, tone: .error)
                }
            }
        }
    }

    private var headline: String {
        guard let deployment = model.deployment else {
            return CompanionHostList.emptyStateMessage(model.hosts)
        }
        return deployment.plainEnglish
    }

    private func hostRow(_ host: CompanionHost) -> some View {
        Button {
            model.selectedHostID = host.id
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(9)) {
                Circle()
                    .strokeBorder(
                        model.selectedHost?.id == host.id
                            ? DashSkin.accent(dark) : DashSkin.line(dark),
                        lineWidth: model.selectedHost?.id == host.id ? 4 : 1.5
                    )
                    .frame(width: UIScale.pt(13), height: UIScale.pt(13))
                    .padding(.top, UIScale.pt(3))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(7)) {
                        Text(host.name)
                            .font(.system(size: UIScale.pt(13), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        if host.hostsTheStack {
                            MindChip(label: "hosts it", tone: .green)
                        }
                        if let tier = host.tier, host.canHostTheStack {
                            MindChip(label: tier.displayName, tone: .green)
                        }
                    }
                    Text(host.summary)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    ForEach(Array(host.blockers.enumerated()), id: \.offset) { _, blocker in
                        Text("\(blocker.headline) · \(blocker.fix)")
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.warn)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var servicesCard: some View {
        SkinCard(
            title: "Services",
            note: "\(model.runningCount) of \(model.services.count) up", dark: dark
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                if model.services.isEmpty {
                    Text("Nothing is running on that machine yet.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else {
                    ForEach(model.services, id: \.service) { service in
                        HStack(spacing: UIScale.pt(8)) {
                            Circle()
                                .fill(service.running ? DashSkin.ok : DashSkin.warn)
                                .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                            Text(service.service)
                                .font(.system(size: UIScale.pt(12), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                            Text(service.status)
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            Spacer(minLength: 0)
                            Text(service.ports)
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    CompanionButton(title: "Start", disabled: model.busy != nil) {
                        Task { await model.start() }
                    }
                    CompanionButton(title: "Stop", disabled: model.busy != nil) {
                        Task { await model.stop() }
                    }
                    CompanionButton(title: "Restart", disabled: model.busy != nil) {
                        Task { await model.restart() }
                    }
                    CompanionButton(title: "Logs", disabled: model.busy != nil) {
                        Task { await model.readLogs(nil) }
                    }
                    if let busy = model.busy {
                        CompanionStatusLine(text: "\(busy)…", tone: .info)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var configurationCard: some View {
        SkinCard(title: "Configuration", note: "what the stack is given", dark: dark) {
            VStack(alignment: .leading, spacing: CompanionMetrics.rowSpacing) {
                HStack(alignment: .top, spacing: UIScale.pt(12)) {
                    portField("API port", value: $model.config.apiPort)
                    portField("Postgres", value: $model.config.pgPort)
                    portField("Redis", value: $model.config.redisPort)
                    Spacer(minLength: 0)
                }
                CompanionLabeledField(
                    label: "Embedding model", placeholder: "qwen3-embedding:0.6b",
                    text: $model.config.embedModel,
                    onSubmit: { model.saveConfig() })
                CompanionLabeledField(
                    label: "Vision model", placeholder: "qwen3-vl:2b",
                    text: $model.config.visionModel,
                    onSubmit: { model.saveConfig() })
                CompanionLabeledField(
                    label: "Reasoning model", placeholder: "qwen3:1.7b",
                    text: $model.config.reasonModel,
                    onSubmit: { model.saveConfig() })
                CompanionLabeledField(
                    label: "Reasoning endpoint", placeholder: "http://ollama:11434/v1",
                    text: $model.config.reasonURL,
                    onSubmit: { model.saveConfig() })
                HStack(spacing: UIScale.pt(8)) {
                    CompanionButton(title: "Save", role: .primary) { model.saveConfig() }
                    CompanionButton(title: "Export…") { exporting = true }
                    CompanionButton(title: "Import…") { importing = true }
                    if let status = model.configStatus {
                        CompanionStatusLine(
                            text: status, tone: model.configStatusIsError ? .error : .ok)
                    }
                    Spacer(minLength: 0)
                }
                Text("Exports carry ports, models and the host. Secrets never leave the Keychain.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private var secretsCard: some View {
        SkinCard(title: "Keys and tokens", note: "kept in your Keychain", dark: dark) {
            VStack(alignment: .leading, spacing: CompanionMetrics.rowSpacing) {
                secretField(
                    "Anthropic API key", kind: .anthropicKey, text: $model.secrets.anthropicKey)
                secretField("GitHub token", kind: .githubToken, text: $model.secrets.githubToken)
                secretField("Notion token", kind: .notionToken, text: $model.secrets.notionToken)
                HStack(spacing: UIScale.pt(8)) {
                    CompanionButton(title: "Save keys", role: .primary) { model.saveSecrets() }
                    if let status = model.secretsStatus {
                        CompanionStatusLine(text: status, tone: .ok)
                    }
                    Spacer(minLength: 0)
                }
                Text(
                    "Blank fields leave the stored value alone; Clear removes one. They are "
                        + "written into the stack's environment when it starts, so they can be "
                        + "set before it exists."
                )
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private func secretField(
        _ label: String, kind: CompanionSecretKind, text: Binding<String>
    ) -> some View {
        CompanionSecureField(
            label: label, placeholder: model.secretHint(kind), text: text,
            detail: model.secretHint(kind) == "not set" ? "not set" : "stored",
            detailEmphasis: model.secretHint(kind) != "not set",
            clear: model.secretHint(kind) == "not set"
                ? nil : { model.clearSecret(kind) },
            onSubmit: { model.saveSecrets() })
    }

    private var teardownCard: some View {
        SkinCard(title: "Danger zone", note: "the stack, not just the app", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                CompanionDangerRow(
                    title: "Destroy the stack and its data",
                    consequence:
                        "Runs compose down with the volumes: containers, database, vault and "
                        + "models all go. Export from Settings first if the memory matters.",
                    buttonTitle: "Destroy…", busy: model.busy == "Destroying",
                    disabled: model.busy != nil && model.busy != "Destroying"
                ) {
                    confirmingDestroy = true
                }
                Divider().opacity(0.3)
                CompanionDangerRow(
                    title: "Forget this deployment",
                    consequence:
                        "Only clears the record on this Mac of where the stack runs. "
                        + "Nothing on the host is touched.",
                    buttonTitle: "Forget", disabled: model.busy != nil
                ) {
                    model.forgetDeployment()
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(16))
                .strokeBorder(DashSkin.danger.opacity(0.35), lineWidth: UIScale.pt(1))
        }
    }

    private var logCard: some View {
        SkinCard(title: "Last output", note: "from its host", dark: dark) {
            ScrollView {
                Text(model.lastLog)
                    .font(.system(size: UIScale.pt(11), design: .monospaced))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: UIScale.pt(200))
        }
    }

    private func portField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            CompanionFieldLabel(text: label)
            EdithNumberField(value: value, width: UIScale.pt(84))
        }
    }
}

struct CompanionConfigDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
