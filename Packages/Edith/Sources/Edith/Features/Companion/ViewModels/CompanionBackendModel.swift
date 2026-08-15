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

    func load() {
        deployment = CompanionDeploymentStore.load()
        config = CompanionConfigStore.load()
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
            let deployment = try await CompanionStackControl.deploy(host: host, config: self.config)
            self.deployment = deployment
        }
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
        let problems = config.validated()
        guard problems.isEmpty else {
            error = problems.joined(separator: "; ")
            return
        }
        CompanionConfigStore.save(config)
        error = nil
    }

    func saveSecrets() {
        CompanionSecrets.set(secrets.anthropicKey, kind: .anthropicKey)
        CompanionSecrets.set(secrets.githubToken, kind: .githubToken)
        CompanionSecrets.set(secrets.notionToken, kind: .notionToken)
        secrets = CompanionSecretValues()
        error = nil
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
