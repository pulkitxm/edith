import CoreWLAN
import Foundation

public struct NetworkCommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool

    public init(status: Int32, output: String, timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }
}

private final class NetworkProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel, process.isRunning { process.terminate() }
    }

    func finish() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        lock.unlock()
        if active?.isRunning == true { active?.terminate() }
    }
}

public enum NetworkProcessRunner {
    public static func run(
        executable: URL, arguments: [String], timeout: Double
    ) async -> NetworkCommandResult {
        let handle = NetworkProcessHandle()
        let operation = Task.detached(priority: .utility) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.qualityOfService = .utility
            handle.attach(process)
            defer { handle.finish() }
            do {
                try process.run()
            } catch {
                return NetworkCommandResult(status: 127, output: error.localizedDescription)
            }
            let reader = Task.detached(priority: .utility) {
                pipe.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            let data = await reader.value
            let bounded = data.prefix(128 * 1024)
            return NetworkCommandResult(
                status: process.terminationStatus,
                output: String(decoding: bounded, as: UTF8.self))
        }
        return await withTaskCancellationHandler {
            await withTaskGroup(of: NetworkCommandResult?.self) { group in
                group.addTask { await operation.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(max(0.1, timeout)))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                guard let first else {
                    handle.cancel()
                    _ = await operation.value
                    return NetworkCommandResult(status: 124, output: "Timed out", timedOut: true)
                }
                return first
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

public struct NetworkDiagnosticsEngine: Sendable {
    public typealias CommandExecutor =
        @Sendable (URL, [String], Double) async -> NetworkCommandResult

    private let command: CommandExecutor

    public init(
        command: @escaping CommandExecutor = { executable, arguments, timeout in
            await NetworkProcessRunner.run(
                executable: executable, arguments: arguments, timeout: timeout)
        }
    ) {
        self.command = command
    }

    public func diagnose(
        configuration rawConfiguration: NetworkDiagnosticsConfiguration,
        baseline: NetworkDiagnosticSnapshot? = nil
    ) async -> NetworkDiagnosticSnapshot {
        let started = Date()
        let configuration = rawConfiguration.normalized
        let route = await command(
            URL(fileURLWithPath: "/sbin/route"), ["-n", "get", "default"],
            configuration.timeoutSeconds)
        let interfaceName = field("interface", in: route.output)
        let gateway = field("gateway", in: route.output)
        let address = await interfaceAddress(
            interfaceName, timeout: configuration.timeoutSeconds)
        let dnsResult = await command(
            URL(fileURLWithPath: "/usr/sbin/scutil"), ["--dns"],
            configuration.timeoutSeconds)
        let proxyResult = await command(
            URL(fileURLWithPath: "/usr/sbin/scutil"), ["--proxy"],
            configuration.timeoutSeconds)
        let vpnResult = await command(
            URL(fileURLWithPath: "/usr/sbin/scutil"), ["--nc", "list"],
            configuration.timeoutSeconds)
        let dnsServers = parseDNSServers(dnsResult.output)
        let wifi = wifiSummary(interfaceName: interfaceName)
        var checks = [
            NetworkDiagnosticCheck(
                id: "interface", title: "Current interface",
                state: interfaceName == nil ? .failed : .healthy,
                summary: interfaceName.map { "Active on \($0)" } ?? "No default interface found",
                detail: address ?? ""),
            NetworkDiagnosticCheck(
                id: "route", title: "Default route",
                state: gateway == nil ? .failed : .healthy,
                summary: gateway.map { "Gateway \($0)" } ?? "No default gateway found"),
            NetworkDiagnosticCheck(
                id: "dns-resolvers", title: "DNS resolvers",
                state: dnsServers.isEmpty ? .failed : .healthy,
                summary: dnsServers.isEmpty
                    ? "No resolver addresses found" : "\(dnsServers.count) resolver address(es)"),
        ]
        if Task.isCancelled { return cancelledSnapshot(started: started, checks: checks) }
        checks.append(
            await dnsCheck(configuration.dnsName, configuration: configuration))
        if let gateway {
            checks.append(
                await pingCheck(
                    id: "gateway", title: "Gateway reachability", host: gateway,
                    configuration: configuration))
        }
        if !configuration.targetHost.isEmpty {
            checks.append(
                configuration.excludes(configuration.targetHost)
                    ? excludedCheck(
                        id: "target", title: "Target reachability",
                        host: configuration.targetHost)
                    : await pingCheck(
                        id: "target", title: "Target reachability",
                        host: configuration.targetHost, configuration: configuration))
        }
        let http = await httpCheck(
            id: "http", title: "HTTP connectivity", target: configuration.httpTarget,
            requiredScheme: "http", configuration: configuration)
        if let check = http.check { checks.append(check) }
        let https = await httpCheck(
            id: "https", title: "HTTPS connectivity", target: configuration.httpsTarget,
            requiredScheme: "https", configuration: configuration)
        if let check = https.check { checks.append(check) }
        if let original = http.originalHost, let final = http.finalHost {
            checks.append(
                NetworkDiagnosticCheck(
                    id: "captive-portal", title: "Captive portal hint",
                    state: original.caseInsensitiveCompare(final) == .orderedSame
                        ? .healthy : .warning,
                    summary: original.caseInsensitiveCompare(final) == .orderedSame
                        ? "No unexpected HTTP redirect detected"
                        : "HTTP probe was redirected to a different host",
                    detail: "\(original) to \(final)"))
        }
        for service in configuration.serviceTargets {
            checks.append(await serviceCheck(service, configuration: configuration))
        }
        let publicAddress =
            configuration.publicIPEnabled
            ? await publicAddress(timeout: configuration.timeoutSeconds) : nil
        if configuration.publicIPEnabled {
            checks.append(
                NetworkDiagnosticCheck(
                    id: "public-ip", title: "Public IP lookup",
                    state: publicAddress == nil ? .warning : .healthy,
                    summary: publicAddress == nil
                        ? "Lookup did not return an address" : "Available",
                    detail: publicAddress ?? ""))
        }
        let path = NetworkPathSummary(
            interfaceName: interfaceName, localAddress: address, gateway: gateway,
            dnsServers: dnsServers, wifiName: wifi.name, wifiBSSID: wifi.bssid,
            wifiRSSI: wifi.rssi, proxyHint: proxyHint(proxyResult.output),
            vpnHint: vpnHint(vpnResult.output), publicAddress: publicAddress)
        let state: NetworkDiagnosticState =
            if checks.contains(where: { $0.state == .failed }) {
                .failed
            } else if checks.contains(where: { $0.state == .warning }) {
                .warning
            } else if checks.contains(where: { $0.state == .healthy }) {
                .healthy
            } else {
                .skipped
            }
        return NetworkDiagnosticSnapshot(
            durationMS: Date().timeIntervalSince(started) * 1000, state: state, path: path,
            checks: checks
        ).compared(with: baseline)
    }

    private func interfaceAddress(_ name: String?, timeout: Double) async -> String? {
        guard let name else { return nil }
        let result = await command(
            URL(fileURLWithPath: "/sbin/ifconfig"), [name], timeout)
        return firstMatch(#"\binet\s+([^\s]+)"#, in: result.output)
    }

    private func dnsCheck(
        _ name: String, configuration: NetworkDiagnosticsConfiguration
    ) async -> NetworkDiagnosticCheck {
        guard !name.isEmpty else {
            return NetworkDiagnosticCheck(
                id: "dns-lookup", title: "DNS lookup timing", state: .skipped,
                summary: "Add a DNS name to run this check")
        }
        guard !configuration.excludes(name) else {
            return excludedCheck(id: "dns-lookup", title: "DNS lookup timing", host: name)
        }
        return await retried(configuration.retries) {
            let started = Date()
            let result = await command(
                URL(fileURLWithPath: "/usr/bin/dscacheutil"),
                ["-q", "host", "-a", "name", name], configuration.timeoutSeconds)
            let elapsed = Date().timeIntervalSince(started) * 1000
            return NetworkDiagnosticCheck(
                id: "dns-lookup", title: "DNS lookup timing",
                state: result.status == 0 && result.output.contains("ip_address")
                    ? .healthy : .failed,
                summary: result.status == 0 ? "Resolved \(name)" : "Could not resolve \(name)",
                detail: result.timedOut ? "Timed out" : "", durationMS: elapsed)
        }
    }

    private func pingCheck(
        id: String, title: String, host: String,
        configuration: NetworkDiagnosticsConfiguration
    ) async -> NetworkDiagnosticCheck {
        await retried(configuration.retries) {
            let result = await command(
                URL(fileURLWithPath: "/sbin/ping"),
                [
                    "-n", "-c", String(configuration.pingCount), "-W",
                    String(Int(configuration.timeoutSeconds * 1000)), host,
                ], configuration.timeoutSeconds * Double(configuration.pingCount) + 1)
            let loss = firstMatch(#"([0-9.]+)% packet loss"#, in: result.output).flatMap(
                Double.init)
            let average = firstMatch(
                #"(?:round-trip|round trip).* = [0-9.]+/([0-9.]+)/"#,
                in: result.output
            ).flatMap(Double.init)
            let state: NetworkDiagnosticState =
                if result.timedOut || loss == 100 {
                    .failed
                } else if result.status != 0 || (loss ?? 0) > 0 {
                    .warning
                } else {
                    .healthy
                }
            return NetworkDiagnosticCheck(
                id: id, title: title, state: state,
                summary: state == .healthy ? "Reachable" : "Reachability degraded",
                detail: result.timedOut ? "Timed out" : host, durationMS: average,
                packetLossPercent: loss)
        }
    }

    private func httpCheck(
        id: String, title: String, target: String, requiredScheme: String,
        configuration: NetworkDiagnosticsConfiguration
    ) async -> (check: NetworkDiagnosticCheck?, originalHost: String?, finalHost: String?) {
        guard !target.isEmpty else { return (nil, nil, nil) }
        guard let url = URL(string: target), url.scheme?.lowercased() == requiredScheme,
            let host = url.host
        else {
            return (
                NetworkDiagnosticCheck(
                    id: id, title: title, state: .failed,
                    summary: "Target must be a valid \(requiredScheme.uppercased()) URL"),
                nil, nil
            )
        }
        guard !configuration.excludes(host) else {
            return (excludedCheck(id: id, title: title, host: host), host, nil)
        }
        var last: NetworkDiagnosticCheck?
        var finalHost: String?
        for _ in 0...configuration.retries {
            let started = Date()
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = configuration.timeoutSeconds
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutSeconds
            sessionConfiguration.timeoutIntervalForResource = configuration.timeoutSeconds
            let session = URLSession(configuration: sessionConfiguration)
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                finalHost = http.url?.host
                let state: NetworkDiagnosticState = http.statusCode < 500 ? .healthy : .warning
                last = NetworkDiagnosticCheck(
                    id: id, title: title, state: state,
                    summary: "HTTP \(http.statusCode)", detail: http.url?.absoluteString ?? target,
                    durationMS: Date().timeIntervalSince(started) * 1000)
                if state == .healthy { break }
            } catch {
                last = NetworkDiagnosticCheck(
                    id: id, title: title, state: .failed,
                    summary: "Connection failed", detail: error.localizedDescription,
                    durationMS: Date().timeIntervalSince(started) * 1000)
            }
            session.invalidateAndCancel()
        }
        return (last, host, finalHost)
    }

    private func serviceCheck(
        _ service: NetworkServiceTarget, configuration: NetworkDiagnosticsConfiguration
    ) async -> NetworkDiagnosticCheck {
        let title = "Service \(service.host):\(service.port)"
        guard !configuration.excludes(service.host) else {
            return excludedCheck(id: "service-\(service.id)", title: title, host: service.host)
        }
        return await retried(configuration.retries) {
            let started = Date()
            let result = await command(
                URL(fileURLWithPath: "/usr/bin/nc"),
                [
                    "-G", String(Int(configuration.timeoutSeconds)), "-z", service.host,
                    String(service.port),
                ], configuration.timeoutSeconds + 1)
            return NetworkDiagnosticCheck(
                id: "service-\(service.id)", title: title,
                state: result.status == 0 ? .healthy : .failed,
                summary: result.status == 0 ? "Port accepted a connection" : "Port unavailable",
                durationMS: Date().timeIntervalSince(started) * 1000)
        }
    }

    private func publicAddress(timeout: Double) async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        let value = String(decoding: data.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func retried(
        _ retries: Int, operation: () async -> NetworkDiagnosticCheck
    ) async -> NetworkDiagnosticCheck {
        var result = await operation()
        guard result.state == .failed else { return result }
        for _ in 0..<retries {
            guard !Task.isCancelled else { return result }
            result = await operation()
            if result.state != .failed { return result }
        }
        return result
    }

    private func field(_ name: String, in text: String) -> String? {
        firstMatch("(?m)^\\s*\(NSRegularExpression.escapedPattern(for: name)):\\s*(\\S+)", in: text)
    }

    private func parseDNSServers(_ text: String) -> [String] {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"(?m)^\s*nameserver\[[0-9]+\]\s*:\s*(\S+)"#)
        else { return [] }
        var seen = Set<String>()
        return expression.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let value = String(text[range])
            return seen.insert(value).inserted ? value : nil
        }
    }

    private func proxyHint(_ text: String) -> String? {
        let enabled = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable"].filter {
            text.range(of: "\($0) : 1") != nil
        }.map { $0.replacingOccurrences(of: "Enable", with: "") }
        return enabled.isEmpty ? nil : enabled.joined(separator: ", ") + " configured"
    }

    private func vpnHint(_ text: String) -> String? {
        let lines = text.split(separator: "\n")
        let configured = lines.filter { line in
            ["(Connected)", "(Disconnected)", "(Connecting)", "(Disconnecting)"].contains {
                state in line.contains(state)
            }
        }.count
        let connected = lines.filter { $0.contains("(Connected)") }.count
        guard configured > 0 || connected > 0 else { return nil }
        return connected > 0 ? "\(connected) connected" : "\(configured) configured"
    }

    private func wifiSummary(interfaceName: String?) -> (name: String?, bssid: String?, rssi: Int?)
    {
        guard let interface = CWWiFiClient.shared().interface(),
            interfaceName == nil || interface.interfaceName == interfaceName
        else { return (nil, nil, nil) }
        return (interface.ssid(), interface.bssid(), interface.rssiValue())
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private func excludedCheck(id: String, title: String, host: String) -> NetworkDiagnosticCheck {
        NetworkDiagnosticCheck(
            id: id, title: title, state: .skipped,
            summary: "Excluded by settings", detail: host)
    }

    private func cancelledSnapshot(
        started: Date, checks: [NetworkDiagnosticCheck]
    ) -> NetworkDiagnosticSnapshot {
        NetworkDiagnosticSnapshot(
            durationMS: Date().timeIntervalSince(started) * 1000, state: .warning,
            path: NetworkPathSummary(),
            checks: checks + [
                NetworkDiagnosticCheck(
                    id: "cancelled", title: "Diagnostic run", state: .skipped,
                    summary: "Cancelled")
            ])
    }
}
