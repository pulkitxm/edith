import EdithExtensionUI
import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class CompanionBackendModel: CompanionRefreshable {
    private let remote: CompanionUIBridge?
    private var remoteTask: Task<Void, Never>?
    private var remoteStopped = false
    init(remote: CompanionUIBridge? = nil) { self.remote = remote }
    func shutdown() { remoteStopped = true; remoteTask?.cancel(); remoteTask = nil }
    private(set) var hosts: [CompanionHost] = []
    private(set) var deployment: CompanionDeployment?
    private(set) var services: [CompanionServiceStatus] = []
    private(set) var probing = false
    private(set) var busy: String?
    private(set) var error: String?
    private(set) var lastLog = ""
    private(set) var configStatus: String?
    private(set) var configStatusIsError = false
    private(set) var secretsStatus: String?
    private(set) var secretHints: [CompanionSecretKind: String] = [:]
    var selectedHostID: UUID?
    var config = CompanionStackConfig()
    var secrets = CompanionSecretValues()

    var selectedHost: CompanionHost? {
        hosts.first { $0.id == selectedHostID } ?? CompanionHostList.recommended(hosts)
    }

    var canDeploy: Bool {
        guard let host = selectedHost, busy == nil else { return false }
        return host.canHostTheStack
    }

    var runningCount: Int { services.filter(\.running).count }

    func refreshSnapshot() async {
        if remote != nil { await remoteAction("snapshot") } else { load() }
    }

    func refresh() async {
        if remote != nil { await remoteAction("refresh"); return }
        load()
        async let probed: Void = probeHosts()
        async let refreshed: Void = refreshServices()
        _ = await (probed, refreshed)
    }

    private var configPrimed = false

    func load() {
        if remote != nil { launchRemote("snapshot"); return }
        deployment = CompanionDeploymentStore.load()
        if !configPrimed {
            config = CompanionConfigStore.load()
            configPrimed = true
        }
        selectedHostID = selectedHostID ?? deployment.flatMap { $0.machineID }
        refreshSecretHints()
    }

    func probeHosts() async {
        if remote != nil { await remoteAction("probe"); return }
        guard !probing else { return }
        probing = true
        defer { probing = false }
        load()
        hosts = await CompanionHosts.all(deployment: deployment)
    }

    func refreshServices() async {
        if remote != nil { await remoteAction("services"); return }
        guard let deployment else {
            services = []
            return
        }
        services = await CompanionStackControl.services(deployment)
    }

    func deploy() async {
        if remote != nil { await remoteAction("deploy"); return }
        guard let host = selectedHost else { return }
        await perform("Setting up on \(host.name)") {
            let deployment = try await CompanionMindRuntimeOperationExecution.deploy {
                try await CompanionStackControl.deploy(
                    host: host, config: self.config,
                    log: { line in
                        Task { @MainActor in self.lastLog += line + "\n" }
                    })
            }
            self.deployment = deployment
        }
    }

    func destroy() async {
        if remote != nil { await remoteAction("destroy"); return }
        guard let deployment else { return }
        await perform("Destroying") {
            self.lastLog = try await CompanionStackControl.run(
                CompanionStackCommands.down(
                    directory: deployment.directory, tier: deployment.resolvedTier,
                    keepData: false),
                on: deployment, timeout: 600)
            CompanionDeploymentStore.clear()
            self.deployment = nil
            self.services = []
        }
    }

    func forgetDeployment() {
        if remote != nil { launchRemote("forget"); return }
        CompanionDeploymentStore.clear()
        deployment = nil
        services = []
        error = nil
    }

    func start() async {
        if remote != nil { await remoteAction("start"); return }
        guard let deployment else { return }
        await perform("Starting") {
            self.lastLog = try await CompanionStackControl.up(deployment)
        }
    }

    func stop() async {
        if remote != nil { await remoteAction("stop"); return }
        guard let deployment else { return }
        await perform("Stopping") {
            self.lastLog = try await CompanionStackControl.down(deployment)
        }
    }

    func restart() async {
        if remote != nil { await remoteAction("restart"); return }
        guard let deployment else { return }
        await perform("Restarting") {
            self.lastLog = try await CompanionStackControl.restart(deployment)
        }
    }

    func readLogs(_ service: String?) async {
        if remote != nil { await remoteAction("logs", service: service); return }
        guard let deployment else { return }
        await perform("Reading logs") {
            self.lastLog = try await CompanionStackControl.logs(deployment, service: service)
        }
    }

    func saveConfig() {
        if remote != nil { launchRemote("config"); return }
        configPrimed = true
        let problems = config.validated()
        guard problems.isEmpty else {
            configStatus = problems.joined(separator: "; ")
            configStatusIsError = true
            return
        }
        CompanionConfigStore.save(config)
        configStatus = "Saved. The stack picks this up next time it starts."
        configStatusIsError = false
    }

    func saveSecrets() {
        if remote != nil { launchRemote("secrets"); return }
        var written = 0
        for (value, kind) in [
            (secrets.anthropicKey, CompanionSecretKind.anthropicKey),
            (secrets.githubToken, .githubToken),
            (secrets.notionToken, .notionToken),
        ] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            CompanionSecrets.set(trimmed, kind: kind)
            written += 1
        }
        secrets = CompanionSecretValues()
        secretsStatus =
            written == 0
            ? "Nothing to save; paste a key first or use Clear to remove one."
            : "Saved \(written) value(s) to the Keychain."
        refreshSecretHints()
    }

    func clearSecret(_ kind: CompanionSecretKind) {
        if remote != nil { launchRemote("clearSecret", kind: kind); return }
        CompanionSecrets.set("", kind: kind)
        secretsStatus = "Cleared."
        refreshSecretHints()
    }

    func secretHint(_ kind: CompanionSecretKind) -> String {
        secretHints[kind] ?? "not set"
    }

    private func refreshSecretHints() {
        for kind in CompanionSecretKind.allCases {
            secretHints[kind] =
                CompanionSecrets.get(kind).flatMap(CompanionSecrets.hint) ?? "not set"
        }
    }

    func exportBundle() -> Data? {
        try? CompanionConfigBundle.encode(
            CompanionConfigBundle(config: config, deployment: deployment))
    }

    func importBundle(_ data: Data) {
        if remote != nil { launchRemote("import", bundle: data); return }
        do {
            let bundle = try CompanionConfigBundle.decode(data)
            config = CompanionConfigStore.save(bundle.config)
            if let imported = bundle.deployment {
                deployment = CompanionDeploymentStore.save(imported)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func launchRemote(
        _ action: String, kind: CompanionSecretKind? = nil, bundle: Data? = nil
    ) {
        remoteTask?.cancel()
        remoteTask = Task { await remoteAction(action, kind: kind, bundle: bundle) }
    }
    private func remoteAction(
        _ action: String, service: String? = nil, kind: CompanionSecretKind? = nil,
        bundle: Data? = nil
    ) async {
        guard let remote, !remoteStopped else { return }
        do {
            var value = try await remote.backend(
                .init(
                    action: action, selectedHostID: selectedHostID, config: config,
                    secrets: action == "secrets" ? secrets : nil, service: service, kind: kind,
                    bundle: bundle))
            while value.working || value.busy != nil || value.probing {
                try Task.checkCancellation()
                guard !remoteStopped else { return }
                applyRemote(value)
                try await Task.sleep(for: .milliseconds(250))
                value = try await remote.backend(
                    .init(
                        action: "snapshot", selectedHostID: nil, config: config, secrets: nil,
                        service: nil, kind: nil, bundle: nil))
            }
            guard !remoteStopped, !Task.isCancelled else { return }
            applyRemote(value)
            if action == "secrets" { secrets = .init() }
        } catch { if !remoteStopped, !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func applyRemote(_ value: CompanionBackendState) {
        hosts = value.hosts; deployment = value.deployment; services = value.services
        selectedHostID = value.selectedHostID; config = value.config; probing = value.probing
        busy = value.busy; error = value.error; lastLog = value.lastLog
        configStatus = value.configStatus; configStatusIsError = value.configStatusIsError
        secretsStatus = value.secretsStatus; secretHints = value.secretHints
    }
    private func perform(_ label: String, _ work: @escaping () async throws -> Void) async {
        guard busy == nil else { return }
        busy = label
        defer { busy = nil }
        do {
            try await work()
            error = nil
            await refreshServices()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
