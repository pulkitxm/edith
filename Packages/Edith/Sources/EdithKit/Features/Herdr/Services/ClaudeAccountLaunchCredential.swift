import EdithCore
import Foundation

public enum ClaudeAccountLaunchCredential {
    static let prefix = "launch-"
    static let staleMinutes = 10

    public static func fileName() -> String { prefix + UUID().uuidString }

    static func isFileName(_ name: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    static func shellLines(variable: String, path: String, platform: RemoteMachinePlatform)
        -> [String]
    {
        if platform == .windows {
            let file = PowerShell.literal(path)
            return [
                "$env:" + variable + "=[IO.File]::ReadAllText(" + file + ")",
                "Remove-Item -LiteralPath " + file + " -Force -ErrorAction SilentlyContinue",
            ]
        }
        let file = ShellQuote.quote(path)
        return ["export " + variable + "=\"$(cat " + file + ")\"", "rm -f " + file]
    }

    static func posixStageCommand(
        accountID: UUID, name: String, identifier: String = AppBuildIdentity.application
    ) throws -> String {
        guard isFileName(name) else { throw ClaudeAccountError.invalidRequest }
        let folder = try ClaudeAccountImport.remoteProfileExpression(
            accountID: accountID, identifier: identifier)
        return try ClaudeAccountImport.remoteScopeValidation(
            accountID: accountID, identifier: identifier)
            + "; umask 077; folder=" + folder
            + "; mkdir -p \"$folder\" && chmod 700 \"$folder\" || exit 1; find \"$folder\" -maxdepth 1 -type f -name '"
            + prefix + "*' -mmin +" + String(staleMinutes)
            + " -exec rm -f {} + 2>/dev/null; file=\"$folder\"/" + name
            + "; (set -C; cat > \"$file\") || exit 1; printf '%s' \"$file\""
    }

    static func windowsStageCommand(
        accountID: UUID, name: String, byteCount: Int,
        identifier: String = AppBuildIdentity.application
    ) throws -> String {
        guard isFileName(name), byteCount > 0, byteCount <= OwnedAccountFiles.maximumBytes else {
            throw ClaudeAccountError.invalidRequest
        }
        _ = try ClaudeAccountImport.remoteProfileExpression(
            accountID: accountID, identifier: identifier)
        let relative = "edith\\" + identifier + "\\accounts\\" + accountID.uuidString
        return PowerShell.command(
            "$ErrorActionPreference='Stop'; $b=New-Object byte[] \(byteCount);"
                + "$i=[Console]::OpenStandardInput();$o=0;while($o-lt $b.Length){"
                + "$n=$i.Read($b,$o,$b.Length-$o);if($n-le 0){break};$o+=$n};"
                + "if($o-ne $b.Length){exit 1};"
                + "if([string]::IsNullOrEmpty($env:LOCALAPPDATA)){exit 1};"
                + "$d=Join-Path $env:LOCALAPPDATA " + PowerShell.literal(relative) + ";"
                + "New-Item -ItemType Directory -Force -Path $d | Out-Null;"
                + "Get-ChildItem -LiteralPath $d -Filter " + PowerShell.literal(prefix + "*")
                + " -File | Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-"
                + String(staleMinutes) + ") } | Remove-Item -Force;"
                + "$p=Join-Path $d " + PowerShell.literal(name) + ";"
                + "$f=[IO.File]::Open($p,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,"
                + "[IO.FileShare]::None);try{$f.Write($b,0,$o)}finally{$f.Dispose()};"
                + "[Console]::Out.Write($p)")
    }

    static func discardCommand(path: String, platform: RemoteMachinePlatform) -> String {
        platform == .windows
            ? PowerShell.command(
                "Remove-Item -LiteralPath " + PowerShell.literal(path)
                    + " -Force -ErrorAction SilentlyContinue")
            : "rm -f -- " + ShellQuote.quote(path)
    }

    static func stagedPath(
        _ output: String, accountID: UUID, name: String, platform: RemoteMachinePlatform,
        identifier: String = AppBuildIdentity.application
    ) throws -> String {
        let separator = platform == .windows ? "\\" : "/"
        let suffix = ((platform == .windows ? [] : [".local", "share"])
            + ["edith", identifier, "accounts", accountID.uuidString, name])
            .joined(separator: separator)
        let absolute =
            platform == .windows
            ? output.range(of: "^[A-Za-z]:\\\\", options: .regularExpression) != nil
            : ClaudeAccountKeychain.absoluteComponents(output) != nil
        guard absolute, output.hasSuffix(separator + suffix), output.utf8.count <= 8192,
            !output.contains(where: { $0.isNewline }), !output.utf8.contains(0)
        else { throw ClaudeAccountError.invalidRequest }
        return output
    }

    static func stage(
        account: ClaudeAccount, connection: SSHConnection, platform: RemoteMachinePlatform
    ) async throws -> String {
        guard account.authentication != .browserLogin else {
            throw ClaudeAccountError.invalidRequest
        }
        let secret = Data(account.credential.utf8)
        let name = fileName()
        let command =
            platform == .windows
            ? try windowsStageCommand(accountID: account.id, name: name, byteCount: secret.count)
            : try posixStageCommand(accountID: account.id, name: name)
        let staged = try await connection.run(command, stdin: secret, timeout: 15)
        try Task.checkCancellation()
        guard staged.succeeded, staged.stdout.count <= 8192,
            let path = try? stagedPath(
                staged.stdoutText, accountID: account.id, name: name, platform: platform)
        else {
            throw ClaudeAccountError.rejected(
                "The selected machine could not prepare the account credential.")
        }
        return path
    }

    static func discard(path: String, connection: SSHConnection, platform: RemoteMachinePlatform)
        async
    {
        _ = try? await connection.run(discardCommand(path: path, platform: platform), timeout: 15)
    }
}
