import EdithKit
import Observation
import SwiftUI

enum CompanionSetupStep: Int, CaseIterable, Identifiable {
    case welcome
    case machine
    case deploy
    case intelligence
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Meet it"
        case .machine: "Pick a machine"
        case .deploy: "Set it up"
        case .intelligence: "Connect a model"
        case .done: "Done"
        }
    }

    var optional: Bool { self == .intelligence }
}

enum CompanionStageState: Equatable {
    case pending
    case running(String)
    case done(String)
    case failed(String)
}

@MainActor
@Observable
final class CompanionSetupModel: Identifiable {
    let id = UUID()
    var step = CompanionSetupStep.welcome
    private(set) var hosts: [CompanionHost] = []
    private(set) var probing = false
    var selectedHostID: UUID?
    private(set) var stages: [CompanionDeployStage: CompanionStageState] = [:]
    private(set) var deploying = false
    private(set) var deployError: String?
    private(set) var deployed: CompanionDeployment?
    var provider = "openai"
    var reasonModel = "qwen3:1.7b"
    var reasonURL = "http://ollama:11434/v1"
    var apiKey = ""
    private(set) var verifying = false
    private(set) var verifyResult: String?
    private(set) var verifyPassed = false
    private(set) var savingReason = false
    let onFinish: (Bool) -> Void

    init(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
    }

    static func initialStep(
        deployment: CompanionDeployment?, reachable: Bool, reasonerConfigured: Bool
    ) -> CompanionSetupStep {
        guard deployment != nil else { return .welcome }
        guard reachable else { return .deploy }
        return reasonerConfigured ? .done : .intelligence
    }

    func begin(home: CompanionHomeModel, reasonerConfigured: Bool) {
        deployed = CompanionDeploymentStore.load()
        step = Self.initialStep(
            deployment: deployed, reachable: home.reachable,
            reasonerConfigured: reasonerConfigured)
        if step == .deploy, let deployed {
            selectedHostID = deployed.machineID ?? CompanionHost.localID
        }
    }

    var selectedHost: CompanionHost? {
        hosts.first { $0.id == selectedHostID } ?? CompanionHostList.recommended(hosts)
    }

    var canContinueFromMachine: Bool {
        selectedHost?.canHostTheStack == true || selectedHost?.hostsTheStack == true
    }

    func probeHosts() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        hosts = await CompanionHosts.all(deployment: CompanionDeploymentStore.load())
        if selectedHostID == nil {
            selectedHostID = CompanionHostList.recommended(hosts)?.id
        }
    }

    func runDeploy() async {
        guard !deploying else { return }
        if selectedHost == nil { await probeHosts() }
        guard let host = selectedHost else {
            deployError =
                "No machine answered the probe; go back a step, wake one up, and probe again."
            return
        }
        deploying = true
        deployError = nil
        stages = [:]
        defer { deploying = false }
        do {
            let deployment = try await CompanionStackControl.deploy(
                host: host, config: CompanionConfigStore.load(),
                progress: { stage, detail in
                    Task { @MainActor in self.advance(to: stage, detail: detail) }
                })
            finishStages()
            deployed = deployment
        } catch {
            failCurrentStage(error.localizedDescription)
            deployError = error.localizedDescription
        }
    }

    private func advance(to stage: CompanionDeployStage, detail: String) {
        for earlier in CompanionDeployStage.allCases {
            if earlier == stage { break }
            if case .running(let note) = stages[earlier] ?? .pending {
                stages[earlier] = .done(note)
            }
            if stages[earlier] == nil || stages[earlier] == .pending {
                stages[earlier] = .done("")
            }
        }
        stages[stage] = .running(detail)
    }

    private func finishStages() {
        for stage in CompanionDeployStage.allCases {
            if case .running(let note) = stages[stage] ?? .pending {
                stages[stage] = .done(note)
            }
        }
    }

    private func failCurrentStage(_ message: String) {
        for stage in CompanionDeployStage.allCases {
            if case .running = stages[stage] ?? .pending {
                stages[stage] = .failed(message)
                return
            }
        }
        stages[.prepare] = .failed(message)
    }

    private var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    func loadReasoner(reachable: Bool) async {
        guard reachable else { return }
        guard let settings = try? await client.reasonSettings() else { return }
        if settings.configured {
            provider = settings.provider == "openai" ? "openai" : "anthropic"
            reasonModel = settings.model
            reasonURL = settings.url
        }
    }

    func saveAndVerifyReasoner() async {
        guard !savingReason, !verifying else { return }
        savingReason = true
        verifying = true
        verifyResult = nil
        defer {
            savingReason = false
            verifying = false
        }
        do {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
            _ = try await client.updateReasonSettings(
                provider: provider,
                url: reasonURL.trimmingCharacters(in: .whitespaces),
                model: reasonModel.trimmingCharacters(in: .whitespaces),
                apiKey: trimmedKey.isEmpty ? nil : trimmedKey)
            apiKey = ""
            let outcome = try await client.testReason()
            verifyPassed = outcome.ok
            verifyResult = "answers in \(outcome.latencyMs) ms"
        } catch {
            verifyPassed = false
            verifyResult = error.localizedDescription
        }
    }
}

struct CompanionSetupSheet: View {
    @Bindable var model: CompanionSetupModel
    let home: CompanionHomeModel
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider().opacity(0.4)
                footer
            }
        }
        .frame(width: UIScale.pt(760), height: UIScale.pt(560))
        .background(DashSkin.paper(dark))
        .task {
            async let probes: Void = model.probeHosts()
            async let reasoner: Void = model.loadReasoner(reachable: home.reachable)
            _ = await (probes, reasoner)
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(0)) {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: UIScale.pt(17)))
                    .foregroundStyle(DashSkin.accent(dark))
                Text("Companion")
                    .font(DashSkin.serif(19, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            .padding(.bottom, UIScale.pt(24))
            ForEach(CompanionSetupStep.allCases) { step in
                stepRow(step)
            }
            Spacer(minLength: 0)
            Text("Everything runs in containers on a machine you choose. Nothing leaves it.")
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(210))
        .background(DashSkin.paper2(dark).opacity(0.5))
    }

    private func stepRow(_ step: CompanionSetupStep) -> some View {
        let state: String =
            step == model.step
            ? "current" : step.rawValue < model.step.rawValue ? "done" : "upcoming"
        return HStack(spacing: UIScale.pt(8)) {
            ZStack {
                Circle()
                    .strokeBorder(
                        state == "upcoming" ? DashSkin.line(dark) : DashSkin.accent(dark),
                        lineWidth: UIScale.pt(1.5)
                    )
                    .background {
                        if state == "current" {
                            Circle().fill(DashSkin.accent(dark))
                        }
                    }
                    .frame(width: UIScale.pt(20), height: UIScale.pt(20))
                if state == "done" {
                    Image(systemName: "checkmark")
                        .font(.system(size: UIScale.pt(9), weight: .bold))
                        .foregroundStyle(DashSkin.accent(dark))
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: UIScale.pt(10), weight: .semibold))
                        .foregroundStyle(
                            state == "current" ? DashSkin.paper(dark) : DashSkin.inkFaint(dark))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(step.title)
                    .font(
                        .system(
                            size: UIScale.pt(12.5),
                            weight: state == "current" ? .semibold : .regular)
                    )
                    .foregroundStyle(
                        state == "upcoming" ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
                if step.optional {
                    Text("optional")
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
        .padding(.vertical, UIScale.pt(9))
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .machine: machinePicker
        case .deploy: deployChecklist
        case .intelligence: intelligence
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text("Meet the companion")
                .font(DashSkin.serif(26, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text(
                "A private memory that lives on your own hardware. It reads what you give "
                    + "it, notices what you actually do, and answers from evidence."
            )
            .font(.system(size: UIScale.pt(12.5)))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                CompanionFieldLabel(text: "What will happen")
                planRow(
                    1, "Pick a machine",
                    "this Mac, or any SSH machine from your fleet")
                planRow(
                    2, "Set it up there",
                    "five containers: the API, Postgres, Redis, Ollama and Whisper; "
                        + "roughly 12 GB of disk")
                planRow(
                    3, "Reach it from here",
                    "a port forward puts it on localhost:4820, opened for you")
                planRow(
                    4, "Verify it",
                    "health checks prove the database, models and vault all answer")
            }
            .padding(.top, UIScale.pt(6))
            Text(
                "Your notes and recordings are stored on that machine only, as plain files "
                    + "and Postgres rows you can export or wipe at any time from Settings."
            )
            .font(.system(size: UIScale.pt(10.5)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, UIScale.pt(4))
        }
        .padding(UIScale.pt(28))
    }

    private func planRow(_ index: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
            Text("\(index)")
                .font(DashSkin.serif(14, weight: .semibold))
                .foregroundStyle(DashSkin.accent(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                Text(title)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(detail)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var machinePicker: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Where should it live?")
                .font(DashSkin.serif(22, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text("Every machine below was just probed. Grayed reasons say what is missing.")
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            ScrollView {
                VStack(spacing: UIScale.pt(8)) {
                    if model.hosts.isEmpty {
                        ListRowsSkeleton(rows: 2, showsLeadingDot: true, dark: dark)
                    }
                    ForEach(model.hosts) { host in
                        hostCard(host)
                    }
                }
            }
            HStack {
                CompanionButton(
                    title: "Probe again", busy: model.probing, busyTitle: "Probing…"
                ) {
                    Task { await model.probeHosts() }
                }
                Spacer()
            }
        }
        .padding(UIScale.pt(28))
    }

    private func hostCard(_ host: CompanionHost) -> some View {
        let selected = model.selectedHostID == host.id
        return Button {
            model.selectedHostID = host.id
        } label: {
            HStack(alignment: .top, spacing: UIScale.pt(10)) {
                Image(systemName: host.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: UIScale.pt(16)))
                    .foregroundStyle(
                        host.canHostTheStack || host.hostsTheStack
                            ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text(host.name)
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                        if host.hostsTheStack {
                            MindChip(label: "hosts it now", tone: .green)
                        }
                    }
                    Text(host.summary)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    ForEach(Array(host.blockers.enumerated()), id: \.offset) { _, blocker in
                        Text("\(blocker.headline) · \(blocker.fix)")
                            .font(.system(size: UIScale.pt(10.5)))
                            .foregroundStyle(DashSkin.warn)
                    }
                }
                Spacer(minLength: 0)
                if host.canHostTheStack || host.hostsTheStack {
                    Text("Ready")
                        .font(.system(size: UIScale.pt(10.5), weight: .medium))
                        .foregroundStyle(DashSkin.ok)
                }
            }
            .padding(UIScale.pt(12))
            .background(
                DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
            )
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(
                        selected ? DashSkin.accent(dark) : DashSkin.line(dark),
                        lineWidth: UIScale.pt(selected ? 1.8 : 1))
            }
            .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var deployChecklist: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Text("Setting up on \(model.selectedHost?.name ?? "the machine")")
                .font(DashSkin.serif(22, weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            VStack(alignment: .leading, spacing: UIScale.pt(0)) {
                ForEach(CompanionDeployStage.allCases, id: \.self) { stage in
                    stageRow(stage)
                }
            }
            .padding(UIScale.pt(12))
            .background(
                DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            if let error = model.deployError {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    CompanionStatusLine(text: error, tone: .error)
                    HStack(spacing: UIScale.pt(8)) {
                        CompanionButton(title: "Retry", role: .primary) {
                            Task { await model.runDeploy() }
                        }
                        CompanionButton(title: "Pick another machine") {
                            model.step = .machine
                        }
                    }
                }
                .padding(UIScale.pt(12))
                .background(
                    DashSkin.danger.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
            } else if !model.deploying, model.deployed != nil {
                CompanionStatusLine(text: "Everything answered. Continue when ready.", tone: .ok)
            } else if model.deploying {
                Text("First-time image pulls and the Rust build can take a few minutes.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(28))
        .task {
            if model.deployed == nil || model.deployError != nil {
                await model.runDeploy()
            } else if model.stages.isEmpty {
                await model.runDeploy()
            }
        }
    }

    private func stageRow(_ stage: CompanionDeployStage) -> some View {
        let state = model.stages[stage] ?? .pending
        return HStack(spacing: UIScale.pt(10)) {
            Group {
                switch state {
                case .pending:
                    Circle()
                        .strokeBorder(DashSkin.line(dark), lineWidth: UIScale.pt(1.5))
                case .running:
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DashSkin.ok)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DashSkin.danger)
                }
            }
            .frame(width: UIScale.pt(18), height: UIScale.pt(18))
            Text(stage.title)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(
                    state == .pending ? DashSkin.inkFaint(dark) : DashSkin.ink(dark))
            Spacer(minLength: 0)
            if case .running(let detail) = state, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, UIScale.pt(7))
    }

    private var intelligence: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(8)) {
                Text("Connect intelligence")
                    .font(DashSkin.serif(22, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("OPTIONAL")
                    .font(.system(size: UIScale.pt(9), weight: .semibold))
                    .tracking(UIScale.pt(0.8))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(.horizontal, UIScale.pt(6))
                    .padding(.vertical, UIScale.pt(2))
                    .overlay { Capsule().strokeBorder(DashSkin.line(dark)) }
            }
            Text(
                "Memory works without this. A reasoner adds chat, reflection and the "
                    + "personas; the bundled Ollama already runs a small local model."
            )
            .font(.system(size: UIScale.pt(11.5)))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                CompanionFieldLabel(text: "Provider")
                Picker("", selection: $model.provider) {
                    Text("Local (Ollama)").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: UIScale.pt(280))
            }
            if model.provider == "openai" {
                CompanionLabeledField(
                    label: "Endpoint URL", placeholder: "http://ollama:11434/v1",
                    text: $model.reasonURL)
            }
            CompanionLabeledField(
                label: "Model",
                placeholder: model.provider == "openai" ? "qwen3:1.7b" : "claude-sonnet-5",
                text: $model.reasonModel)
            if model.provider == "anthropic" {
                CompanionSecureField(
                    label: "API key", placeholder: "sk-…", text: $model.apiKey,
                    onSubmit: { Task { await model.saveAndVerifyReasoner() } })
            }
            HStack(spacing: UIScale.pt(8)) {
                CompanionButton(
                    title: "Save and verify", role: .primary,
                    busy: model.verifying, busyTitle: "Asking it to answer…"
                ) {
                    Task { await model.saveAndVerifyReasoner() }
                }
                if let result = model.verifyResult {
                    CompanionStatusLine(
                        text: result, tone: model.verifyPassed ? .ok : .error)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(28))
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: UIScale.pt(28)))
                    .foregroundStyle(DashSkin.accent(dark))
                Text("The companion is live")
                    .font(DashSkin.serif(26, weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            if let deployment = model.deployed ?? CompanionDeploymentStore.load() {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    summaryRow("Host", deployment.machineName)
                    summaryRow("Reached at", "localhost:\(deployment.localPort)")
                    summaryRow("Tier", deployment.resolvedTier.displayName)
                    summaryRow("Containers", "shown under Backend, and in Machines as Edith's own")
                    summaryRow("Your data", "export, import or wipe it anytime from Settings")
                }
            }
            Text(
                "Drop files anywhere on the Companion window to remember them. Pause, move "
                    + "or reconfigure the stack from the Backend tab whenever you like."
            )
            .font(.system(size: UIScale.pt(11.5)))
            .foregroundStyle(DashSkin.inkSoft(dark))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(28))
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
            Text(label)
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(90), alignment: .trailing)
            Text(value)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
        }
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(8)) {
            if model.step == .intelligence {
                CompanionLinkButton(title: "Skip for now") {
                    model.step = .done
                }
            } else if model.step != .done {
                CompanionLinkButton(title: "Not now") {
                    model.onFinish(false)
                }
            }
            Spacer()
            if model.step != .welcome, model.step != .done, !model.deploying {
                CompanionButton(title: "Back") {
                    model.step =
                        CompanionSetupStep(rawValue: model.step.rawValue - 1) ?? .welcome
                }
            }
            CompanionButton(
                title: primaryTitle, role: .primary, disabled: primaryDisabled
            ) {
                primaryAction()
            }
        }
        .padding(.horizontal, UIScale.pt(20))
        .padding(.vertical, UIScale.pt(14))
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: "Choose a machine"
        case .machine: "Set it up"
        case .deploy: "Continue"
        case .intelligence: "Finish"
        case .done: "Start using it"
        }
    }

    private var primaryDisabled: Bool {
        switch model.step {
        case .machine: !model.canContinueFromMachine
        case .deploy: model.deploying || model.deployed == nil || model.deployError != nil
        default: false
        }
    }

    private func primaryAction() {
        switch model.step {
        case .welcome:
            model.step = .machine
        case .machine:
            model.step = .deploy
        case .deploy:
            model.step = .intelligence
        case .intelligence:
            model.step = .done
        case .done:
            model.onFinish(true)
        }
    }
}
