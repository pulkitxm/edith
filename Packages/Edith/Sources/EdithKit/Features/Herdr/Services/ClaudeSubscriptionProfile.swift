import CryptoKit
import Foundation
import Security

public enum ClaudeSubscriptionProfile {
    static let sharedEntries = [
        "settings.json", "settings.local.json", "CLAUDE.md", "skills", "commands", "agents",
        "plugins", "hooks", "rules",
    ]

    public static func prepare(account: ClaudeAccount, on machine: Machine?) async throws -> String
    {
        if let machine { return try await prepareRemote(account: account, machine: machine) }
        let environment = try await ClaudeAccount.currentCLIEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shared = URL(
            fileURLWithPath: environment["CLAUDE_CONFIG_DIR"]
                ?? home.appendingPathComponent(".claude").path)
        let folder = ClaudeAccountStorage.directory.appendingPathComponent(account.id.uuidString)
        try prepareLocal(account: account, folder: folder, shared: shared, home: home)
        return folder.path
    }

    static func prepareLocal(account: ClaudeAccount, folder: URL, shared: URL, home: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: shared, withIntermediateDirectories: true)
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for entry in sharedEntries {
            let source = shared.appendingPathComponent(entry)
            let target = folder.appendingPathComponent(entry)
            if manager.fileExists(atPath: target.path),
                (try? manager.destinationOfSymbolicLink(atPath: target.path)) == nil
            {
                if !manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: target, to: source)
                } else {
                    try mergeMissing(from: target, into: source)
                    try manager.moveItem(
                        at: target,
                        to: folder.appendingPathComponent(
                            entry + ".before-sharing-" + UUID().uuidString))
                }
            }
            if !manager.fileExists(atPath: source.path), !entry.contains(".") {
                try manager.createDirectory(at: source, withIntermediateDirectories: true)
            }
            if !manager.fileExists(atPath: target.path),
                (try? manager.destinationOfSymbolicLink(atPath: target.path)) == nil
            {
                try manager.createSymbolicLink(at: target, withDestinationURL: source)
            }
        }
        let source =
            shared.lastPathComponent == ".claude"
            ? home.appendingPathComponent(".claude.json")
            : shared.appendingPathComponent(".claude.json")
        let target = folder.appendingPathComponent(".claude.json")
        let merged = try mergedConfiguration(shared: try read(source), profile: try read(target))
        try merged.write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        if let loginData = account.loginData,
            ClaudeSavedLogin.credentials(environment: [
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": folder.path
            ]) == nil
        {
            let data = Data(loginData.utf8)
            let file = folder.appendingPathComponent(".credentials.json")
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let service = credentialService(folder.path)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: NSUserName(), kSecValueData as String: data,
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                throw ClaudeAccountError.rejected(
                    "Could not save the subscription login in this account's keychain.")
            }
        }
    }

    private static func mergeMissing(from source: URL, into target: URL) throws {
        let manager = FileManager.default
        var sourceDirectory: ObjCBool = false
        var targetDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &sourceDirectory),
            manager.fileExists(atPath: target.path, isDirectory: &targetDirectory),
            sourceDirectory.boolValue, targetDirectory.boolValue
        else { return }
        for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let destination = target.appendingPathComponent(child.lastPathComponent)
            if manager.fileExists(atPath: destination.path) {
                if (try? manager.destinationOfSymbolicLink(atPath: child.path)) == nil {
                    try mergeMissing(from: child, into: destination)
                }
            } else {
                try manager.copyItem(at: child, to: destination)
            }
        }
    }

    static func mergedConfiguration(shared: Data?, profile: Data?) throws -> Data {
        let source = try object(shared)
        var target = try object(profile)
        for (key, value) in source where target[key] == nil {
            if !["oauthAccount", "primaryApiKey", "customApiKeyResponses"].contains(key) {
                target[key] = value
            }
        }
        for key in ["mcpServers", "projects"] {
            let defaults = source[key] as? [String: Any] ?? [:]
            let existing = target[key] as? [String: Any] ?? [:]
            target[key] = defaults.merging(existing) { baseline, current in
                guard key == "projects", let baseline = baseline as? [String: Any],
                    var current = current as? [String: Any]
                else { return current }
                for (field, value) in baseline where current[field] == nil {
                    current[field] = value
                }
                let servers = baseline["mcpServers"] as? [String: Any] ?? [:]
                let overrides = current["mcpServers"] as? [String: Any] ?? [:]
                current["mcpServers"] = servers.merging(overrides) { _, value in value }
                return current
            }
        }
        return try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
    }

    private static func object(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard data.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClaudeAccountError.rejected("Could not read the native CLI configuration.") }
        return object
    }

    private static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func credentialService(_ path: String) -> String {
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            .prefix(8)
        return "Claude Code-credentials-" + hash
    }

    private static func prepareRemote(account: ClaudeAccount, machine: Machine) async throws
        -> String
    {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        let platform = await connection.remotePlatform ?? .linux
        let windows = platform == .windows
        let paths = try await connection.run(
            windows
                ? "Write-Output $HOME; Write-Output $env:CLAUDE_CONFIG_DIR"
                : "\"${SHELL:-/bin/sh}\" -lic 'printf \"%s\\n%s\\n\" \"$HOME\" \"${CLAUDE_CONFIG_DIR:-}\"'",
            timeout: 15)
        guard paths.succeeded else { throw HerdrCommandError.commandFailed(paths.stderrText) }
        let values = paths.stdoutText.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .newlines)
        }
        guard let home = values.first, !home.isEmpty else {
            throw ClaudeAccountError.invalidRequest
        }
        let separator = windows ? "\\" : "/"
        let shared =
            values.count > 1 && !values[1].isEmpty ? values[1] : home + separator + ".claude"
        let folder =
            home + separator + ".local" + separator + "share" + separator + "edith" + separator
            + "accounts" + separator + account.id.uuidString
        let quote: (String) -> String = windows ? PowerShell.literal : ShellQuote.quote
        let mkdir =
            windows
            ? "New-Item -ItemType Directory -Force -Path " + quote(folder) + ", " + quote(shared)
                + " | Out-Null"
            : "mkdir -p " + quote(folder) + " " + quote(shared) + " && chmod 700 " + quote(folder)
        let created = try await connection.run(mkdir, timeout: 15)
        guard created.succeeded else { throw HerdrCommandError.commandFailed(created.stderrText) }
        for entry in sharedEntries {
            let source = shared + separator + entry
            let target = folder + separator + entry
            let link: String
            if windows {
                let type = entry.contains(".") ? "HardLink" : "Junction"
                let backup = quote(target + ".before-sharing-" + UUID().uuidString)
                let directory =
                    entry.contains(".")
                    ? ""
                    : "New-Item -ItemType Directory -Force -Path " + quote(source) + " | Out-Null; "
                let merge =
                    entry.contains(".")
                    ? ""
                    : "robocopy " + quote(target) + " " + quote(source)
                        + " /E /XC /XN /XO /NFL /NDL /NJH /NJS | Out-Null; "
                        + "if ($LASTEXITCODE -ge 8) { throw 'Could not retain profile configuration' }; $global:LASTEXITCODE=0; "
                link =
                    directory + "if (Test-Path -LiteralPath " + quote(target)
                    + ") { $item = Get-Item -LiteralPath " + quote(target)
                    + "; if (!$item.LinkType) { if (!(Test-Path -LiteralPath " + quote(source)
                    + ")) { Move-Item -LiteralPath " + quote(target) + " -Destination "
                    + quote(source) + " -ErrorAction Stop } else { " + merge
                    + "Move-Item -LiteralPath " + quote(target) + " -Destination " + backup
                    + " -ErrorAction Stop } } elseif ($item.LinkType -eq 'HardLink') { Remove-Item -LiteralPath "
                    + quote(target) + " -Force } }; if (!(Test-Path -LiteralPath " + quote(target)
                    + ")) { if (Test-Path -LiteralPath " + quote(source) + ") { New-Item -ItemType "
                    + type + " -Path " + quote(target) + " -Target " + quote(source)
                    + " -ErrorAction Stop | Out-Null } }"
            } else {
                let prepare = entry.contains(".") ? "" : "mkdir -p " + quote(source) + "; "
                let backup = quote(target + ".before-sharing-" + UUID().uuidString)
                link =
                    prepare
                    + "if [ -e " + quote(target) + " ] && [ ! -L " + quote(target)
                    + " ]; then if [ ! -e " + quote(source) + " ]; then mv " + quote(target)
                    + " " + quote(source) + "; else if [ -d " + quote(target) + " ] && [ -d "
                    + quote(source) + " ]; then cp -Rn " + quote(target + "/.") + " "
                    + quote(source) + "; fi; mv " + quote(target) + " " + backup + "; fi; fi; "
                    + "if [ ! -e " + quote(target) + " ] && [ ! -L " + quote(target)
                    + " ]; then ln -s " + quote(source) + " " + quote(target) + "; fi"
            }
            let linked = try await connection.run(link, timeout: 15)
            guard linked.succeeded else { throw HerdrCommandError.commandFailed(linked.stderrText) }
        }
        let source =
            shared == home + separator + ".claude"
            ? home + separator + ".claude.json" : shared + separator + ".claude.json"
        let target = folder + separator + ".claude.json"
        func readRemote(_ path: String) async throws -> Data? {
            let command =
                windows
                ? "if (Test-Path -LiteralPath " + quote(path)
                    + ") { [Console]::Out.Write([IO.File]::ReadAllText(" + quote(path) + ")) }"
                : "if [ -f " + quote(path) + " ]; then head -c 1048577 " + quote(path) + "; fi"
            let result = try await connection.run(command, timeout: 15)
            guard result.succeeded else { throw HerdrCommandError.commandFailed(result.stderrText) }
            return result.stdout.isEmpty ? nil : result.stdout
        }
        let merged = try await mergedConfiguration(
            shared: readRemote(source), profile: readRemote(target))
        let write =
            windows
            ? "[IO.File]::WriteAllText(" + quote(target) + ", [Console]::In.ReadToEnd())"
            : "umask 077; cat > " + quote(target)
        let written = try await connection.run(write, stdin: merged, timeout: 15)
        guard written.succeeded else { throw HerdrCommandError.commandFailed(written.stderrText) }
        if let loginData = account.loginData {
            let credentials = folder + separator + ".credentials.json"
            let seed =
                windows
                ? "if (!(Test-Path -LiteralPath " + quote(credentials)
                    + ")) { [IO.File]::WriteAllText(" + quote(credentials)
                    + ", [Console]::In.ReadToEnd()) }"
                : "umask 077; if [ ! -f " + quote(credentials) + " ]; then cat > "
                    + quote(credentials) + "; else cat >/dev/null; fi"
            let seeded = try await connection.run(seed, stdin: Data(loginData.utf8), timeout: 15)
            guard seeded.succeeded else { throw HerdrCommandError.commandFailed(seeded.stderrText) }
            if platform == .darwin {
                let service = quote(credentialService(folder))
                let keychain =
                    "security find-generic-password -s " + service
                    + " >/dev/null 2>&1 || security add-generic-password -a \"$USER\" -s " + service
                    + " -w \"$(cat " + quote(credentials) + ")\""
                let saved = try await connection.run(keychain, timeout: 15)
                guard saved.succeeded else {
                    throw HerdrCommandError.commandFailed(saved.stderrText)
                }
            }
        }
        return folder
    }
}
