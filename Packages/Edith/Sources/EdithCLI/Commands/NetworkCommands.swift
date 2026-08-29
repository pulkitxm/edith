import ArgumentParser
import EdithKit
import Foundation

struct NetworkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network", abstract: "Read-only local network diagnostics.",
        subcommands: [NetworkDiagnoseCommand.self, NetworkBaselineCommand.self],
        defaultSubcommand: NetworkDiagnoseCommand.self)
}

struct NetworkBaselineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline", abstract: "Read the saved healthy network baseline.")

    @Flag(name: .long, help: "Emit redacted JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let snapshot = NetworkDiagnosticsPreferences.baseline() else {
                throw CLIFailure.notFound(
                    "no network baseline has been saved",
                    hint: "run `ed network diagnose --save-baseline`")
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                CLIOut.out(
                    NetworkDiagnosticsRedactor.redact(String(decoding: data, as: UTF8.self)))
            } else {
                CLIOut.out(NetworkDiagnosticsRedactor.report(snapshot))
            }
        }
    }
}

struct NetworkDiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Run explainable route, DNS, reachability, web, and service checks.",
        usage: "ed network diagnose [<options>]")

    @Flag(name: .long, help: "Emit a redacted JSON snapshot on stdout.")
    var json = false

    @Option(name: .long, help: "Ping this explicit host or address.")
    var target: String?

    @Option(name: .long, help: "Resolve this explicit DNS name and time it.")
    var dns: String?

    @Option(name: .customLong("http"), help: "Probe this explicit HTTP URL.")
    var httpTarget: String?

    @Option(name: .customLong("https"), help: "Probe this explicit HTTPS URL.")
    var httpsTarget: String?

    @Option(name: .long, help: "Probe host:port. Repeat for more services.")
    var service: [String] = []

    @Option(name: .long, help: "Skip this host or domain suffix. Repeat as needed.")
    var exclude: [String] = []

    @Flag(name: .long, help: "Perform the normally disabled public IP lookup.")
    var publicIP = false

    @Option(name: .long, help: "Timeout for each attempt in seconds.")
    var timeout: Double?

    @Option(name: .long, help: "Retry a failed check this many times.")
    var retries: Int?

    @Option(name: .long, help: "Packets in each reachability sample.")
    var count: Int?

    @Flag(name: .long, help: "Save this snapshot as the healthy baseline.")
    var saveBaseline = false

    @Flag(name: .long, help: "Do not retain this snapshot in the bounded timeline.")
    var noHistory = false

    func run() async throws {
        try await execute {
            var configuration = NetworkDiagnosticsPreferences.configuration()
            if let target { configuration.targetHost = target }
            if let dns { configuration.dnsName = dns }
            if let httpTarget { configuration.httpTarget = httpTarget }
            if let httpsTarget { configuration.httpsTarget = httpsTarget }
            if !service.isEmpty {
                configuration.serviceTargets = try service.map(parseService)
            }
            if !exclude.isEmpty { configuration.exclusions = exclude }
            if publicIP { configuration.publicIPEnabled = true }
            if let timeout { configuration.timeoutSeconds = timeout }
            if let retries { configuration.retries = retries }
            if let count { configuration.pingCount = count }
            configuration = configuration.normalized
            let baseline = NetworkDiagnosticsPreferences.baseline()
            let snapshot = await NetworkDiagnosticsEngine().diagnose(
                configuration: configuration, baseline: baseline)
            if !noHistory {
                _ = try? await NetworkDiagnosticsTimelineStore.shared.append(
                    snapshot, limit: configuration.timelineLimit)
            }
            if saveBaseline {
                guard snapshot.state == .healthy else {
                    throw CLIFailure(
                        "only a healthy network snapshot can be saved as the baseline")
                }
                NetworkDiagnosticsPreferences.saveBaseline(snapshot)
                AppBridge.post(IPC.Name.settingsChanged)
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                CLIOut.out(
                    NetworkDiagnosticsRedactor.redact(String(decoding: data, as: UTF8.self)))
            } else {
                CLIOut.out(NetworkDiagnosticsRedactor.report(snapshot))
                if saveBaseline { CLIOut.out("Saved as baseline.") }
            }
        }
    }

    private func parseService(_ value: String) throws -> NetworkServiceTarget {
        guard let separator = value.lastIndex(of: ":"),
            let port = Int(value[value.index(after: separator)...]),
            (1...65535).contains(port)
        else {
            throw CLIFailure.usage(
                "invalid service target \(value)",
                hint: "use host:port, for example example.com:443")
        }
        let host = String(value[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw CLIFailure.usage("service host cannot be empty")
        }
        return NetworkServiceTarget(host: host, port: port)
    }
}
