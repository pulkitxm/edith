import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class CompanionBackendModel: CompanionRefreshable {
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

    func refresh() async {
        await probeHosts()
        await refreshServices()
    }

    private var configPrimed = false

    func load() {
        deployment = CompanionDeploymentStore.load()
        if !configPrimed {
            config = CompanionConfigStore.load()
            configPrimed = true
        }
        selectedHostID = selectedHostID ?? deployment.flatMap { $0.machineID }
    }

    func probeHosts() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        load()
        hosts = await CompanionHosts.all(deployment: deployment)
    }

    func refreshServices() async {
        guard let deployment else {
            services = []
            return
        }
        services = await CompanionStackControl.services(deployment)
    }

    func deploy() async {
        guard let host = selectedHost else { return }
        await perform("Setting up on \(host.name)") {
            let deployment = try await CompanionStackControl.deploy(
                host: host, config: self.config,
                log: { line in
                    Task { @MainActor in self.lastLog += line + "\n" }
                })
            self.deployment = deployment
        }
    }

    func destroy() async {
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
        CompanionDeploymentStore.clear()
        deployment = nil
        services = []
        error = nil
    }

    func start() async {
        guard let deployment else { return }
        await perform("Starting") {
            self.lastLog = try await CompanionStackControl.up(deployment)
        }
    }

    func stop() async {
        guard let deployment else { return }
        await perform("Stopping") {
            self.lastLog = try await CompanionStackControl.down(deployment)
        }
    }

    func restart() async {
        guard let deployment else { return }
        await perform("Restarting") {
            self.lastLog = try await CompanionStackControl.restart(deployment)
        }
    }

    func readLogs(_ service: String?) async {
        guard let deployment else { return }
        await perform("Reading logs") {
            self.lastLog = try await CompanionStackControl.logs(deployment, service: service)
        }
    }

    func saveConfig() {
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
    }

    func clearSecret(_ kind: CompanionSecretKind) {
        CompanionSecrets.set("", kind: kind)
        secretsStatus = "Cleared."
    }

    func secretHint(_ kind: CompanionSecretKind) -> String {
        CompanionSecrets.get(kind).flatMap(CompanionSecrets.hint) ?? "not set"
    }

    func exportBundle() -> Data? {
        try? CompanionConfigBundle.encode(
            CompanionConfigBundle(config: config, deployment: deployment))
    }

    func importBundle(_ data: Data) {
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
