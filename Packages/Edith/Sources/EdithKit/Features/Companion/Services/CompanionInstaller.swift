import Foundation

public enum CompanionSource {
    public static let environmentKey = "EDITH_COMPANION_SOURCE"

    public static func locate() -> URL? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment[environmentKey] {
            candidates.append(override)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/Desktop/Edith/apps/companion")
        candidates.append("\(home)/edith/apps/companion")
        for candidate in candidates {
            let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Cargo.toml").path),
                FileManager.default.fileExists(
                    atPath: url.appendingPathComponent("src/main.rs").path)
            {
                return url
            }
        }
        return nil
    }

    public static func tarball(of directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-C", directory.path, "--exclude", "target", "--exclude", ".git", "-czf", "-", ".",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CompanionStackError.commandFailed(
                "tar", detail.isEmpty ? "could not pack the companion source" : detail)
        }
        return data
    }
}

public typealias CompanionCommandRunner = (String, Data?, TimeInterval) async throws -> String

public enum CompanionDeployStage: String, CaseIterable, Sendable {
    case prepare
    case source
    case files
    case env
    case start
    case tunnel
    case health

    public var title: String {
        switch self {
        case .prepare: "Prepare the directory"
        case .source: "Sync the companion source"
        case .files: "Write the compose files"
        case .env: "Write the environment"
        case .start: "Build and start the services"
        case .tunnel: "Open the port forward"
        case .health: "Run the health checks"
        }
    }
}

public typealias CompanionDeployProgress = @Sendable (CompanionDeployStage, String) -> Void

public enum CompanionInstaller {
    @MainActor
    public static func install(
        deployment: CompanionDeployment,
        config: CompanionStackConfig,
        secrets: CompanionSecretValues,
        runner: CompanionCommandRunner? = nil,
        progress: CompanionDeployProgress? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let run: CompanionCommandRunner =
            runner
            ?? { command, stdin, timeout in
                try await CompanionStackControl.run(
                    command, on: deployment, stdin: stdin, timeout: timeout)
            }
        let directory = deployment.directory
        progress?(.prepare, "creating \(directory)")
        log("Preparing \(directory) on \(deployment.machineName)")
        _ = try await run("mkdir -p \(quoted(directory))", nil, 30)

        if let source = CompanionSource.locate() {
            progress?(.source, "from \(source.path)")
            log("Syncing the companion source from \(source.path)")
            let tarball = try CompanionSource.tarball(of: source)
            _ = try await run("tar -xzf - -C \(quoted(directory))", tarball, 300)
        } else if await !sourcePresent(deployment, run) {
            throw CompanionStackError.commandFailed(
                "install",
                "\(directory) has no companion source and none was found on this Mac; "
                    + "set \(CompanionSource.environmentKey) to the apps/companion checkout")
        } else {
            progress?(.source, "already on \(deployment.machineName)")
            log("Keeping the source already on \(deployment.machineName)")
        }

        progress?(.files, CompanionRuntimeFiles.all.map(\.name).joined(separator: ", "))
        for file in CompanionRuntimeFiles.all {
            log("Writing \(file.name)")
            _ = try await run(
                "cat > \(quoted(directory + "/" + file.name))",
                Data(file.content.utf8), 30)
        }

        progress?(.env, "ports, models and Keychain secrets")
        log("Writing .env")
        let env = config.envFile(secrets: secrets)
        _ = try await run(
            "umask 077 && cat > \(quoted(directory + "/.env"))", Data(env.utf8), 30)
    }

    @MainActor
    private static func sourcePresent(
        _ deployment: CompanionDeployment, _ run: CompanionCommandRunner
    ) async -> Bool {
        let probe = "test -f \(quoted(deployment.directory + "/Cargo.toml")) && echo yes"
        let output = try? await run(probe, nil, 20)
        return output?.contains("yes") == true
    }

    private static func quoted(_ path: String) -> String {
        guard path.hasPrefix("~/") else {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let rest = String(path.dropFirst(2))
        return "\"$HOME\"/'" + rest.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

public enum CompanionTunnel {
    @MainActor
    public static func savedForward(for deployment: CompanionDeployment) -> PortForward? {
        guard let machineID = deployment.machineID else { return nil }
        return MachineRegistry.forwards().first {
            $0.machineID == machineID && $0.localPort == deployment.localPort
                && $0.remotePort == deployment.localPort
        }
    }

    @MainActor
    public static func endpointAnswers(_ deployment: CompanionDeployment) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(deployment.localPort)/v1/status")
        else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    @MainActor
    @discardableResult
    public static func ensure(_ deployment: CompanionDeployment) async -> Bool {
        guard let machineID = deployment.machineID else { return true }
        if await endpointAnswers(deployment) { return true }
        guard let machine = MachineRegistry.machines().first(where: { $0.id == machineID })
        else { return false }
        let forward: PortForward
        if let existing = savedForward(for: deployment) {
            forward = existing
        } else {
            forward = PortForward(
                machineID: machineID, localPort: deployment.localPort,
                remoteHost: "localhost", remotePort: deployment.localPort,
                title: "companion")
            MachineRegistry.addForward(forward)
        }
        let session = MachineSession(machine: machine, local: false)
        guard case .success = await session.runCommand("true", timeout: 20) else {
            return false
        }
        return await session.setForward(forward, active: true) == nil
    }
}
