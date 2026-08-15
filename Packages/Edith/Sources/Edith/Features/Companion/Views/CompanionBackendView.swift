import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct CompanionBackendScreen: View {
    @Bindable var model: CompanionBackendModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.companionRequestsEnabled) private var requestsEnabled
    @Environment(\.companionGeneration) private var generation
    @State private var exporting = false
    @State private var importing = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if let error = model.error {
                    Text(error)
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(.orange)
                }
                whereItRunsCard
                if model.deployment != nil { servicesCard }
                configurationCard
                secretsCard
                if !model.lastLog.isEmpty { logCard }
            }
            .pageContent(compact)
        }
        .task(id: generation) { if requestsEnabled { await model.refresh() } }
        .fileExporter(
            isPresented: $exporting,
            document: CompanionConfigDocument(data: model.exportBundle() ?? Data()),
            contentType: .json,
            defaultFilename: "companion-configuration"
        ) { _ in }
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
                    Text(model.probing ? "Looking at your machines…" : "No machines found yet.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else {
                    ForEach(model.hosts) { host in
                        hostRow(host)
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    CompanionAsyncButton(
                        model.deployment == nil ? "Set it up here" : "Move it here",
                        filled: true, disabled: !model.canDeploy
                    ) {
                        await model.deploy()
                    }
                    CompanionAsyncButton("Re-check", disabled: model.probing) {
                        await model.probeHosts()
                    }
                    if let busy = model.busy {
                        Text(busy + "…")
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    Spacer(minLength: 0)
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
                            .foregroundStyle(.orange)
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
                                .fill(service.running ? Color.green : Color.orange)
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
                    CompanionAsyncButton("Start", disabled: model.busy != nil) {
                        await model.start()
                    }
                    CompanionAsyncButton("Stop", disabled: model.busy != nil) {
                        await model.stop()
                    }
                    CompanionAsyncButton("Restart", disabled: model.busy != nil) {
                        await model.restart()
                    }
                    CompanionAsyncButton("Logs", disabled: model.busy != nil) {
                        await model.readLogs(nil)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var configurationCard: some View {
        SkinCard(title: "Configuration", note: "what the stack is given", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                HStack(spacing: UIScale.pt(8)) {
                    numberField("API port", value: $model.config.apiPort)
                    numberField("Postgres", value: $model.config.pgPort)
                    numberField("Redis", value: $model.config.redisPort)
                }
                textField("Embedding model", text: $model.config.embedModel)
                textField("Vision model", text: $model.config.visionModel)
                textField("Reasoning model", text: $model.config.reasonModel)
                textField("Reasoning endpoint", text: $model.config.reasonURL)
                HStack(spacing: UIScale.pt(8)) {
                    Button("Save") { model.saveConfig() }
                        .buttonStyle(.plain)
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.accent(dark))
                        .pointerCursor()
                    Button("Export…") { exporting = true }
                        .buttonStyle(.plain)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .pointerCursor()
                    Button("Import…") { importing = true }
                        .buttonStyle(.plain)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .pointerCursor()
                    Spacer(minLength: 0)
                }
                Text("Exports carry ports, models and the host. Secrets never leave the Keychain.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }

    private var secretsCard: some View {
        SkinCard(title: "Keys and tokens", note: "kept in your Keychain", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                secretRow(
                    "Anthropic API key", kind: .anthropicKey, text: $model.secrets.anthropicKey)
                secretRow("GitHub token", kind: .githubToken, text: $model.secrets.githubToken)
                secretRow("Notion token", kind: .notionToken, text: $model.secrets.notionToken)
                HStack(spacing: UIScale.pt(8)) {
                    Button("Save keys") { model.saveSecrets() }
                        .buttonStyle(.plain)
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.accent(dark))
                        .pointerCursor()
                    Spacer(minLength: 0)
                }
                Text(
                    "These are written into the stack's environment when it starts, so they can "
                        + "be set before it exists."
                )
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            }
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

    private func secretRow(
        _ label: String, kind: CompanionSecretKind, text: Binding<String>
    ) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Text(label)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(130), alignment: .leading)
            SecureField(model.secretHint(kind), text: text)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(12.5)))
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(6))
                .background(DashSkin.paper2(dark))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
    }

    private func textField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: UIScale.pt(8)) {
            Text(label)
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(130), alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(12.5)))
                .padding(.horizontal, UIScale.pt(8))
                .padding(.vertical, UIScale.pt(6))
                .background(DashSkin.paper2(dark))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
    }

    private func numberField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(label)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            TextField(
                label,
                value: value,
                format: .number.grouping(.never)
            )
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(12.5)))
            .padding(.horizontal, UIScale.pt(8))
            .padding(.vertical, UIScale.pt(6))
            .background(DashSkin.paper2(dark))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
            .frame(width: UIScale.pt(90))
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
